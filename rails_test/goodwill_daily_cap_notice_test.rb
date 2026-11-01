# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class GoodwillDailyCapNoticeTest < ActionDispatch::IntegrationTest
        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @rules = Decidim::Bih::Goodwill::EarningRules.new
        end

        # Decidim::EventsManager.publish enqueues its own :events-queue
        # delivery chain (EventPublisherJob -> NotificationGeneratorJob ->
        # NotificationGeneratorForRecipientJob). The shared :test adapter only
        # RECORDS enqueued jobs by default; it never performs them. Scope it to
        # actually perform :events jobs for THIS test class only (restored in
        # teardown below) so the assertions below can see a real
        # Decidim::Notification row — every other rails_test file, and every
        # other queue (:reports, :goodwill, :integrations, ...), is untouched.
        setup do
          @previous_queue_adapter_queue = ActiveJob::Base.queue_adapter.queue
          @previous_perform_enqueued_jobs = ActiveJob::Base.queue_adapter.perform_enqueued_jobs
          ActiveJob::Base.queue_adapter.queue = :events
          ActiveJob::Base.queue_adapter.perform_enqueued_jobs = true
        end

        # The generated Rails test host defaults config.cache_store to
        # :null_store (writes/reads are no-ops), same as this engine's real
        # host app in test env; production runs :redis_cache_store, a real
        # store. EarningRules' once-per-day cap-notice dedup relies on
        # Rails.cache read-after-write, so it is correct in production but
        # unobservable under :null_store. Swap in a real in-process store for
        # THIS test class only (a fresh instance per test, so nothing leaks
        # between examples), restored in teardown below.
        setup do
          @previous_cache_store = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
        end

        teardown do
          Rails.cache = @previous_cache_store
          ActiveJob::Base.queue_adapter.queue = @previous_queue_adapter_queue
          ActiveJob::Base.queue_adapter.perform_enqueued_jobs = @previous_perform_enqueued_jobs
        end

        test "eleventh like of the day earns nothing but is still recorded" do
          10.times { |i| @rules.award(@citizen, :like, idempotency_key: "like-#{i}") }
          account = Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen)
          earned_after_ten = account.reload.contribution_score

          assert_equal 10, earned_after_ten, "10 lajkova po 1 bod"

          capped = @rules.award(@citizen, :like, idempotency_key: "like-11")

          assert_nil capped, "11. lajk ne smije proizvesti transakciju"
          assert_equal earned_after_ten, account.reload.contribution_score
        end

        test "eleventh vote of the day earns nothing but is still recorded" do
          10.times { |i| @rules.award(@citizen, :vote, idempotency_key: "vote-#{i}") }
          account = Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen)
          earned_after_ten = account.reload.contribution_score

          assert_equal 20, earned_after_ten, "10 glasova po 2 boda"
          assert_nil @rules.award(@citizen, :vote, idempotency_key: "vote-11")
          assert_equal earned_after_ten, account.reload.contribution_score
        end

        test "sixth comment of the day earns nothing but is still published" do
          5.times { |i| @rules.award(@citizen, :comment, idempotency_key: "comment-#{i}") }
          account = Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen)
          earned_after_five = account.reload.contribution_score

          assert_equal 15, earned_after_five, "5 komentara po 3 boda"
          assert_nil @rules.award(@citizen, :comment, idempotency_key: "comment-6")
          assert_equal earned_after_five, account.reload.contribution_score
        end

        test "reaching the cap notifies the citizen exactly once per action per day" do
          10.times { |i| @rules.award(@citizen, :like, idempotency_key: "notice-like-#{i}") }

          notices = lambda do
            Decidim::Notification
              .where(decidim_user_id: @citizen.id)
              .where(event_class: "Decidim::Bih::Goodwill::DailyCapReachedEvent")
              .count
          end

          @rules.award(@citizen, :like, idempotency_key: "notice-like-11")
          assert_equal 1, notices.call

          @rules.award(@citizen, :like, idempotency_key: "notice-like-12")
          assert_equal 1, notices.call, "poruka se ne ponavlja isti dan za istu radnju"
        end

        test "cap resets on the next calendar day in Europe/Sarajevo" do
          Time.use_zone("Europe/Sarajevo") do
            travel_to Time.zone.local(2026, 9, 8, 23, 30) do
              10.times { |i| @rules.award(@citizen, :like, idempotency_key: "tz-like-#{i}") }
              assert_nil @rules.award(@citizen, :like, idempotency_key: "tz-like-11")
            end

            travel_to Time.zone.local(2026, 9, 9, 0, 15) do
              assert @rules.award(@citizen, :like, idempotency_key: "tz-like-next-day"),
                     "poslije ponoći po Sarajevu granica se resetuje"
            end
          end
        end

        test "an externally-claimed notice slot is never republished" do
          10.times { |i| @rules.award(@citizen, :like, idempotency_key: "claim-like-#{i}") }

          # Simulira konkurentnu dodjelu koja je već atomski zauzela slot za
          # ovu radnju/dan (npr. drugi goodwill worker, vidi
          # config/sidekiq.yml concurrency 5) prije nego što je ovaj poziv
          # stigao do notify_daily_cap_reached.
          key = @rules.send(:daily_cap_notice_key, @citizen, :like)
          Rails.cache.write(key, true, expires_in: 24.hours, unless_exist: true)

          @rules.award(@citizen, :like, idempotency_key: "claim-like-11")

          notices = Decidim::Notification
                    .where(decidim_user_id: @citizen.id)
                    .where(event_class: "Decidim::Bih::Goodwill::DailyCapReachedEvent")
                    .count

          assert_equal 0, notices, "spolja zauzet slot ne smije proizvesti obavijest"
        end
      end
    end
  end
end

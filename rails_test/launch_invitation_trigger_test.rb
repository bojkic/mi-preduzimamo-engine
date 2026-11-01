# frozen_string_literal: true

require "test_helper"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module RailsHarness
      class LaunchInvitationTriggerTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        Service = Decidim::Bih::Goodwill::LaunchInvitation

        # Scoped to only: LaunchInvitationJob (not a bare `perform_enqueued_jobs
        # do`). Every award here also fires Ledger's existing :events chain
        # (EventPublisherJob -> NotificationGeneratorJob /
        # EmailNotificationGeneratorJob), and several tests cross a
        # goodwill_contributor badge level (badge.levels start at 10 — see
        # engine.rb), which Decidim notifies by real email to a FactoryBot user
        # (notifications_sending_frequency defaults to "real_time"). Actually
        # PERFORMING that email job would have premailer-rails fetch the mailer
        # layout's packed CSS over real HTTP from this test's fake per-run host
        # (rails-test-<hex>.lvh.me) — nothing is listening there, so it would
        # hang/ECONNREFUSED. None of that is under test: `score` reads the
        # ledger directly and `invitation` only needs LaunchInvitationJob to
        # have run, so scoping to it is sufficient and keeps this file from
        # ever touching shared test infrastructure or a third-party gem.
        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @rules = Decidim::Bih::Goodwill::EarningRules.new
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20, stock: 450,
            deducts_points: false, auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
          Rails.cache.clear
        end

        # Slučajevi 1-6 iz specifikacije, kroz stvarne dodjele bodova.
        test "verification plus komsiluk gives 20 points and issues the invitation" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            @rules.award(@citizen, :verification, idempotency_key: "verification:#{@citizen.id}")
            @rules.award(@citizen, :komsiluk_selected, idempotency_key: "komsiluk_selected:#{@citizen.id}")
          end

          assert_equal 20, score
          assert invitation
        end

        test "registration plus one report reaches 40 and issues the invitation" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            register!
            report = eligible_report!
            @rules.award(@citizen, :report, idempotency_key: "bih_report:#{report.id}")
          end

          assert_equal 40, score
          assert invitation, "40 bodova mora izdati pozivnicu"
        end

        test "registration plus one proposal reaches 45 and issues the invitation" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            register!
            component = FactoryBot.create(:proposal_component, organization: @organization)
            proposal = FactoryBot.create(:proposal, component:, users: [@citizen], published_at: Time.current)
            @rules.award(@citizen, :proposal, idempotency_key: "proposal:#{proposal.id}:author:#{@citizen.id}")
          end

          assert_equal 45, score
          assert invitation
        end

        test "registration plus one verified referral reaches 45 and issues the invitation" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            register!
            @rules.award(@citizen, :referral, idempotency_key: "referral:1")
          end

          assert_equal 45, score
          assert invitation
        end

        test "registration plus two komsiluk posts reaches 40 and issues the invitation" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            register!
            @rules.award(@citizen, :komsiluk_post, idempotency_key: "komsiluk_post:1")
            @rules.award(@citizen, :komsiluk_post, idempotency_key: "komsiluk_post:2")
          end

          assert_equal 40, score
          assert invitation
        end

        test "registration plus debate, comment and vote reaches 40 and issues the invitation" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            register!
            @rules.award(@citizen, :debate, idempotency_key: "debate:1:author:#{@citizen.id}")
            @rules.award(@citizen, :comment, idempotency_key: "comment:1")
            @rules.award(@citizen, :vote, idempotency_key: "proposal_vote:1:voter:#{@citizen.id}")
          end

          assert_equal 40, score
          assert invitation
        end

        test "a citizen on 19 points gets no invitation" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 19, reason: "test_seed")
          end

          assert_equal 19, score
          assert_nil invitation
        end

        test "crossing 50 points reaches the Aktivista level" do
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::LaunchInvitationJob) do
            Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 55, reason: "test_seed")
          end

          level = Decidim::Bih::Goodwill::Levels.for(score)
          assert_equal "aktivista", level.key
        end

        # Fix round 1: Ledger#maybe_issue_launch_invitation registers the job
        # enqueue inside ActiveRecord.after_all_transactions_commit. When the
        # award runs inside an already-open transaction — the NORMAL case,
        # since EarningRules#award opens its own — that block is executed by
        # Rails AFTER the real COMMIT, with no rescue of its own. A raise in
        # there (a transient Redis/Sidekiq hiccup is enough) must never escape
        # through EarningRules#award and turn an already-committed award into
        # an unhandled 500 for the citizen. Stubbing perform_later to raise
        # exercises exactly that deferred path, no perform_enqueued_jobs
        # needed — the callback fires on real transaction commit regardless
        # of the ActiveJob test adapter's perform_enqueued_jobs setting.
        test "an enqueue failure inside the deferred after-commit callback never breaks the award" do
          Decidim::Bih::Goodwill::LaunchInvitationJob.stub(
            :perform_later, ->(_user_id) { raise "simulated Sidekiq hiccup" }
          ) do
            register!
            report = eligible_report!
            result = @rules.award(@citizen, :report, idempotency_key: "bih_report:#{report.id}")

            assert result, "dodjela mora uspjeti i kad zakazivanje pozivnice pukne"
          end

          assert_equal 40, score, "bodovi moraju ostati upisani uprkos padu zakazivanja"
        end

        private

        def eligible_report!
          Decidim::Bih::Report.create!(organization: @organization, author: @citizen,
            description: "Prijava u testu pozivnice", status: "u_obradi", review_state: "validated")
        end

        def register!
          @rules.award(@citizen, :verification, idempotency_key: "verification:#{@citizen.id}")
          @rules.award(@citizen, :komsiluk_selected, idempotency_key: "komsiluk_selected:#{@citizen.id}")
        end

        def score
          Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen).reload.contribution_score
        end

        def invitation
          Decidim::Bih::Goodwill::RewardFulfillment.find_by(
            organization: @organization, user: @citizen, reward_key: Service::REWARD_KEY
          )
        end
      end
    end
  end
end

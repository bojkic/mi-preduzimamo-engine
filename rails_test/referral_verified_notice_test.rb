# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The referrer hears about the invitee's first verification at once (bell
      # only, no name), and the points follow after ReferralRewardJob::REWARD_DELAY
      # — 24 hours since the owner decision of 2026-09-12.
      class ReferralVerifiedNoticeTest < ActionDispatch::IntegrationTest
        include ActiveJob::TestHelper

        EVENT = "Decidim::Bih::Goodwill::ReferralVerifiedEvent"

        setup do
          @organization = create_organization(badges_enabled: false)
          @referrer = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana_poziva")
          @invitee = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "mila_nova")
          Decidim::Bih::Goodwill::Referrals.attribute(invitee: @invitee, code: "ana_poziva")
        end

        # Perform only the :events chain (EventPublisherJob → NotificationGenerator…)
        # so a real Decidim::Notification row appears; goodwill jobs stay recorded.
        setup do
          @previous_queue = ActiveJob::Base.queue_adapter.queue
          @previous_perform = ActiveJob::Base.queue_adapter.perform_enqueued_jobs
          ActiveJob::Base.queue_adapter.queue = :events
          ActiveJob::Base.queue_adapter.perform_enqueued_jobs = true
        end

        teardown do
          ActiveJob::Base.queue_adapter.queue = @previous_queue
          ActiveJob::Base.queue_adapter.perform_enqueued_jobs = @previous_perform
        end

        def notices_for(user)
          Decidim::Notification.where(decidim_user_id: user.id, event_class: EVENT)
        end

        test "the first grant tells the referrer, names nobody, and quotes points and the wait" do
          FactoryBot.create(:authorization, :granted, user: @invitee, name: "sms")

          assert_equal 1, notices_for(@referrer).count
          assert_equal 0, notices_for(@invitee).count, "the invitee is not told about their own referral"

          notice = notices_for(@referrer).first
          assert_equal 25, notice.extra["points"]
          assert_equal 24, notice.extra["hours"]

          title = notice.event_class_instance.notification_title
          assert_includes title, "25"
          assert_includes title, "24"
          refute_includes title, "mila_nova", "no invitee name in the referrer's notice"
          refute_includes title, @invitee.name
        end

        # Being told an invite worked is the moment a referrer is most likely to
        # send another, so the bell item has to be a way back to the invite tab.
        # The notifications cell renders notification_title as HTML and ignores
        # resource_path entirely, so the anchor has to live inside the title —
        # the same shape PointsEarnedEvent uses.
        test "the notice links back to the invite tab" do
          FactoryBot.create(:authorization, :granted, user: @invitee, name: "sms")

          notice = notices_for(@referrer).first
          event = notice.event_class_instance

          assert_equal Decidim::Bih.invite_path, event.resource_path

          title = event.notification_title
          assert_includes title, %(href="#{Decidim::Bih.invite_path}"),
                          "the bell item carries a link to the invite tab"
          # Ambient locale, not a forced :sr — the generated harness host renders
          # in English, and the point of the assertion is that the title carries
          # the SAME string the event looked up, in whatever locale is active.
          assert_includes title, I18n.t("decidim.bih.goodwill.events.referral_verified.invite_more")
        end

        test "a second, different authorization for the same invitee does not notify again" do
          FactoryBot.create(:authorization, :granted, user: @invitee, name: "sms")
          FactoryBot.create(:authorization, :granted, user: @invitee, name: "postal_letter")

          assert_equal 1, notices_for(@referrer).count
        end

        test "no notice when nobody invited the citizen" do
          stranger = FactoryBot.create(:user, :confirmed, organization: @organization)
          FactoryBot.create(:authorization, :granted, user: stranger, name: "sms")

          assert_equal 0, Decidim::Notification.where(event_class: EVENT).count
        end

        test "the reward job waits REWARD_DELAY, which is 24 hours" do
          assert_equal 24.hours, Decidim::Bih::Goodwill::ReferralRewardJob::REWARD_DELAY

          FactoryBot.create(:authorization, :granted, user: @invitee, name: "sms")

          job = enqueued_jobs.find { |j| j["job_class"] == "Decidim::Bih::Goodwill::ReferralRewardJob" }
          assert job, "the reward job is scheduled on the grant"
          delay_hours = (Time.zone.parse(job["scheduled_at"].to_s) - Time.zone.parse(job["enqueued_at"].to_s)) / 3600.0
          assert_in_delta 24.0, delay_hours, 0.1
        end
      end
    end
  end
end

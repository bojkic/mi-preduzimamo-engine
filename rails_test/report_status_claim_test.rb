# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportStatusClaimTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @author = FactoryBot.create(:user, :confirmed, organization: @organization)
          @report = Decidim::Bih::Report.create!(
            organization: @organization, author: @author, reporter_email: @author.email,
            description: "Broken pavement.", category: "putevi", severity: "normalan",
            status: "primljeno", address: "Harness street 1", latitude: 44.758, longitude: 19.214
          )
        end

        def with_push_available(&block)
          Decidim::Bih::WebPush.stub(:available_for?, true, &block)
        end

        test "a proven pre-claim push refusal chooses a currently eligible report email" do
          email_calls = []
          viber_calls = []
          # The typed producer owns the availability check. A separate probe
          # could fail before any claim and silently lose the alternate.
          Decidim::Bih::WebPush.stub(:available_for?, ->(*) { raise "preclaim probe must not run" }) do
            Decidim::Bih::WebPush.stub(:enqueue_with_claim_result, :not_claimed) do
              Decidim::Bih::Messaging::ProactiveEmail.stub(:report_allowed?, true) do
                @report.stub(:enqueue_email_notification, ->(locale) { email_calls << locale }) do
                  @report.stub(:enqueue_viber_notification, ->(locale) { viber_calls << locale }) do
                    assert_difference "Decidim::Notification.count", 1 do
                      @report.send(:notify_reporter_of_status_change)
                    end
                  end
                end
              end
            end
          end
          assert_equal [@organization.default_locale], email_calls
          assert_empty viber_calls
        end

        test "uncertain push claim leaves the inbox and does not choose another proactive route" do
          email_calls = []
          viber_calls = []
          with_push_available do
            Decidim::Bih::WebPush.stub(:enqueue_with_claim_result, :uncertain) do
              @report.stub(:enqueue_email_notification, ->(locale) { email_calls << locale }) do
                @report.stub(:enqueue_viber_notification, ->(locale) { viber_calls << locale }) do
                  assert_difference "Decidim::Notification.count", 1 do
                    @report.send(:notify_reporter_of_status_change)
                  end
                end
              end
            end
          end
          assert_empty email_calls
          assert_empty viber_calls
          notification = Decidim::Notification.where(decidim_user_id: @author.id).order(:id).last
          assert_equal "uncertain", notification.extra.fetch("mi_report_push_claim")
          assert_equal 1, Decidim::Bih::Messaging::Reconciliation.report(
            organization: @organization, since: 1.hour.ago
          ).fetch(:report_push_claim_uncertain_recorded)
        end

        test "pre-claim fallback rechecks the account contact email gate" do
          email_calls = []
          viber_calls = []
          with_push_available do
            Decidim::Bih::WebPush.stub(:enqueue_with_claim_result, :not_claimed) do
              Decidim::Bih::Messaging::ProactiveEmail.stub(:report_allowed?, false) do
                @report.stub(:enqueue_email_notification, ->(locale) { email_calls << locale }) do
                  @report.stub(:enqueue_viber_notification, ->(locale) { viber_calls << locale }) do
                    @report.send(:notify_reporter_of_status_change)
                  end
                end
              end
            end
          end
          assert_empty email_calls
          assert_equal [@organization.default_locale], viber_calls
        end

        test "push result distinguishes no claim from a durable but uncertain queue" do
          push = Decidim::Bih::WebPush
          subscription = { "endpoint" => "https://fcm.googleapis.com/fcm/send/test", "p256dh" => "key", "auth" => "auth" }
          @author.stub(:notifications_subscriptions, { "test" => subscription }) do
            push.stub(:enabled?, true) do
              push.stub(:topic_permitted?, ->(*) { raise "preclaim check unavailable" }) do
                assert_equal :not_claimed,
                             push.enqueue_with_claim_result(@author, topic: :report_updates, notification_id: 1)
              end
              push.stub(:topic_permitted?, true) do
                push.stub(:valid_subscription?, false) do
                  assert_equal :not_claimed,
                               push.enqueue_with_claim_result(@author, topic: :report_updates, notification_id: 1)
                end
                push.stub(:valid_subscription?, true) do
                  push.stub(:delivery_intent, Object.new) do
                    push.stub(:enqueue_devices, false) do
                      assert_equal :uncertain,
                                   push.enqueue_with_claim_result(@author, topic: :report_updates, notification_id: 1)
                    end
                    push.stub(:enqueue_devices, true) do
                      assert_equal :claimed_or_queued,
                                   push.enqueue_with_claim_result(@author, topic: :report_updates, notification_id: 1)
                    end
                  end
                  push.stub(:delivery_intent, ->(*) { raise "queue evidence unavailable" }) do
                    assert_equal :uncertain,
                                 push.enqueue_with_claim_result(@author, topic: :report_updates, notification_id: 1)
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

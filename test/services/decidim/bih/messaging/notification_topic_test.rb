# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/topic_preferences"
require_relative "../../../../../app/services/decidim/bih/messaging/notification_topic"

module Decidim
  module Bih
    module Messaging
      class NotificationTopicTest < Minitest::Test
        def test_report_case_and_status_belong_to_reports
          %w(report_case_message report_status_updated report_received report_overdue).each do |event|
            assert_equal "report_updates", NotificationTopic.for_event("decidim.events.bih.#{event}")
          end
        end

        def test_geographic_notices_share_the_neighborhood_choice
          %w(komsiluk_post local_broadcast city_service_alert).each do |event|
            assert_equal "neighborhood_info", NotificationTopic.for_event("decidim.events.bih.#{event}")
          end
        end

        def test_launch_and_welcome_are_platform_news
          %w(launch_invitation_waiting_for_phone welcome_notification).each do |event|
            assert_equal "platform_news", NotificationTopic.for_event("decidim.events.bih.#{event}")
          end
        end

        def test_participation_and_conversations_are_community_news
          %w(decidim.events.proposals.proposal_endorsed decidim.events.bih.goodwill.points_earned decidim.events.bih.volunteer.decision).each do |event|
            assert_equal "community_news", NotificationTopic.for_event(event)
          end
          assert_equal "community_news", NotificationTopic.for(Struct.new(:conversation).new(:conversation))
        end

        def test_case_bound_operator_message_carries_explicit_topic
          assert_equal "report_updates", NotificationTopic.for_event("decidim.events.bih.operator.message", extra: { notification_topic: "report_updates" })
          assert_raises(ArgumentError) { NotificationTopic.for_event("event", extra: { notification_topic: "not_a_topic" }) }
        end
      end
    end
  end
end

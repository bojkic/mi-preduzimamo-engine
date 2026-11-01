# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "../../../../app/services/decidim/bih/topic_preferences"
require_relative "../../../../app/services/decidim/bih/notification_preferences"

module Decidim
  module Bih
    class NotificationPreferencesTest < Minitest::Test
      def test_every_transport_uses_the_same_topic_choice
        calls = []
        TopicPreferences.stub(:enabled?, lambda { |user, topic:|
          calls << [user, topic]
          false
        }) do
          NotificationPreferences::CHANNELS.each do |channel|
            refute NotificationPreferences.permitted?(:user, topic: :report_updates, channel:)
          end
        end
        assert_equal 4, calls.size
        assert_equal [[:user, :report_updates]], calls.uniq
      end

      def test_bells_ignore_the_old_opt_out_and_the_proactive_topic
        TopicPreferences.stub(:enabled?, ->(*) { flunk "bells must not consult proactive choices" }) do
          assert NotificationPreferences.enabled?(:user, topic: :komsiluk_urgent, channel: :bell, default: false)
        end
      end

      def test_legacy_setting_write_changes_the_whole_topic
        writes = []
        TopicPreferences.stub(:set!, ->(user, **attributes) { writes << [user, attributes] }) do
          NotificationPreferences.set!(:user, topic: :report_updates, channel: :viber, enabled: false)
        end
        assert_equal [[:user, { topic: :report_updates, enabled: false, source: "account" }]], writes
      end

      def test_provider_stop_cannot_be_written_as_a_topic_refusal
        assert_raises(ArgumentError) do
          NotificationPreferences.set!(:user, topic: :report_updates, channel: :viber, enabled: false, source: "provider_opt_out")
        end
      end
    end
  end
end

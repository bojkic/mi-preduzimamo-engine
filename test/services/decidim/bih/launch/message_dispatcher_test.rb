# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require_relative "../../../../../app/services/decidim/bih/launch/message_dispatcher"

module Decidim
  module Bih
    module Launch
      class MessageDispatcherTest < Minitest::Test
        Notification = Struct.new(:status) do
          def reload = self

          def channels = ["viber"]
        end

        class NotificationsDouble
          class << self
            attr_accessor :eligible, :status, :enqueues, :dispatches

            def preview(**) = { eligible: }

            def enqueue!(**options)
              enqueues << options
              Notification.new(status)
            end

            def dispatch!(notification) = dispatches << notification
          end
        end

        module TopicPreferencesDouble
          def self.enabled?(_user, topic:) = topic.to_s == "platform_news"
        end

        class DispatcherProbe < MessageDispatcher
          attr_reader :legacy_phone_attempts, :email_attempts

          def initialize(...)
            super
            @legacy_phone_attempts = @email_attempts = 0
          end

          private

          def marketing_channels(*) = MARKETING_CHANNELS

          def message_class_for(*) = nil

          def phone_permitted?(*) = true

          def email_permitted?(*) = true

          def render_if_present(*) = "Community message"

          def whatsapp_template_for(*) = { name: "approved-campaign", language: "sr", body: { "1" => "news" } }

          def deliver_phone(*)
            @legacy_phone_attempts += 1
            true
          end

          def deliver_email(*)
            @email_attempts += 1
            true
          end
        end

        def setup
          @previous_topics = Decidim::Bih.const_get(:TopicPreferences, false) if Decidim::Bih.const_defined?(:TopicPreferences, false)
          Decidim::Bih.send(:remove_const, :TopicPreferences) if @previous_topics
          Decidim::Bih.const_set(:TopicPreferences, TopicPreferencesDouble)
          @previous = Decidim::Bih.const_get(:AccountNotifications, false) if Decidim::Bih.const_defined?(:AccountNotifications, false)
          Decidim::Bih.send(:remove_const, :AccountNotifications) if @previous
          Decidim::Bih.const_set(:AccountNotifications, NotificationsDouble)
          NotificationsDouble.eligible = true
          NotificationsDouble.status = "accepted"
          NotificationsDouble.enqueues = []
          NotificationsDouble.dispatches = []
          @user = Struct.new(:id).new(42)
          @organization = Struct.new(:id).new(7)
          @dispatcher = DispatcherProbe.new(@user, organization: @organization)
        end

        def teardown
          Decidim::Bih.send(:remove_const, :TopicPreferences)
          Decidim::Bih.const_set(:TopicPreferences, @previous_topics) if @previous_topics
          Decidim::Bih.send(:remove_const, :AccountNotifications)
          Decidim::Bih.const_set(:AccountNotifications, @previous) if @previous
        end

        def test_marketing_uses_shared_consent_and_existing_campaign_identity
          assert_equal :phone, @dispatcher.deliver("p9")
          intent = NotificationsDouble.enqueues.fetch(0)
          assert_equal :platform_news, intent[:topic]
          assert_equal "launch:p9", intent[:deduplication_key]
          assert_equal %w(email messenger instagram viber whatsapp), intent[:channels]
          assert_equal @user, intent[:user]
          assert_equal @organization, intent[:organization]
          assert_equal 0, @dispatcher.legacy_phone_attempts
          assert_equal 0, @dispatcher.email_attempts
        end

        def test_optout_never_falls_through_to_email_or_old_phone_sender
          NotificationsDouble.eligible = false
          assert_equal :undeliverable, @dispatcher.deliver("p4")
          assert_empty NotificationsDouble.enqueues
          assert_equal 0, @dispatcher.legacy_phone_attempts
          assert_equal 0, @dispatcher.email_attempts
        end

        def test_ambiguous_outcome_does_not_start_email_fallback
          NotificationsDouble.status = "unknown"
          assert_equal :undeliverable, @dispatcher.deliver("p5")
          assert_equal 1, NotificationsDouble.dispatches.size
          assert_equal 0, @dispatcher.email_attempts
        end

        def test_existing_requested_invitation_transport_is_preserved
          assert_equal :phone, @dispatcher.deliver("p1")
          assert_equal 1, @dispatcher.legacy_phone_attempts
          assert_empty NotificationsDouble.enqueues
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require_relative "../../../../app/services/decidim/bih/volunteer_notifications"

module Decidim
  unless const_defined?(:EventsManager, false)
    module EventsManager
    end
  end

  unless EventsManager.respond_to?(:publish)
    EventsManager.define_singleton_method(:publish) do |**_payload|
      raise "stub publish in tests"
    end
  end

  module Bih
    const_set(:VolunteerDecisionEvent, Class.new) unless const_defined?(:VolunteerDecisionEvent, false)

    class VolunteerNotificationsTest < Minitest::Test
      User = Struct.new(:id, keyword_init: true)

      class FakeLogger
        attr_reader :messages

        def initialize
          @messages = []
        end

        def error(message)
          @messages << message
        end
      end

      def test_blank_user_returns_nil_without_publishing
        published = false

        Decidim::EventsManager.stub(:publish, lambda { |**_payload|
          published = true
        }) do
          assert_nil VolunteerNotifications.publish(
            user: nil,
            kind: :opportunity,
            status: :approved,
            title: "Park cleanup"
          )
        end

        assert_equal false, published
      end

      def test_publish_sends_volunteer_decision_event_payload
        user = User.new(id: 42)
        payloads = []

        Decidim::EventsManager.stub(:publish, lambda { |**payload|
          payloads << payload
          :published
        }) do
          assert_equal :published, VolunteerNotifications.publish(
            user:,
            kind: :opportunity,
            status: :approved,
            title: :park_cleanup,
            reason: 123
          )
        end

        assert_equal 1, payloads.length
        payload = payloads.first

        assert_equal "decidim.events.bih.volunteer.decision", payload.fetch(:event)
        assert_same Decidim::Bih::VolunteerDecisionEvent, payload.fetch(:event_class)
        assert_same user, payload.fetch(:resource)
        assert_equal [user], payload.fetch(:affected_users)
        assert_equal true, payload.fetch(:force_send)
        assert_equal(
          {
            kind: "opportunity",
            status: "approved",
            title: "park_cleanup",
            reason: "123"
          },
          payload.fetch(:extra)
        )
      end

      def test_publisher_exception_is_logged_and_rescued
        user = User.new(id: 77)
        logger = FakeLogger.new

        with_rails_logger(logger) do
          Decidim::EventsManager.stub(:publish, lambda { |**_payload|
            raise "notification bus unavailable"
          }) do
            assert_nil VolunteerNotifications.publish(
              user:,
              kind: :log,
              status: :rejected,
              title: "Volunteer hours"
            )
          end
        end

        assert_equal 1, logger.messages.length
        message = logger.messages.first

        assert_includes message, "user 77"
        assert_includes message, "RuntimeError"
        assert_includes message, "notification bus unavailable"
      end

      private

      def with_rails_logger(logger)
        return with_existing_rails_logger(logger) { yield } if Object.const_defined?(:Rails)

        rails_module = Module.new
        rails_module.define_singleton_method(:logger) { logger }
        Object.const_set(:Rails, rails_module)
        yield
      ensure
        if defined?(rails_module) &&
           Object.const_defined?(:Rails) &&
           Object.const_get(:Rails).equal?(rails_module)
          Object.send(:remove_const, :Rails)
        end
      end

      def with_existing_rails_logger(logger)
        return Rails.stub(:logger, logger) { yield } if Rails.respond_to?(:logger)

        Rails.define_singleton_method(:logger) { logger }
        yield
      ensure
        if Object.const_defined?(:Rails) &&
           Rails.respond_to?(:logger) &&
           Rails.logger.equal?(logger)
          Rails.singleton_class.send(:remove_method, :logger)
        end
      end
    end
  end
end

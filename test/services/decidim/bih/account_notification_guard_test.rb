# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "../../../../app/services/decidim/bih/account_notifications"
require_relative "../../../../app/services/decidim/bih/report_push_followup"

module Decidim
  module Bih
    class AccountNotificationGuardTest < Minitest::Test
      def setup
        @previous_guard = AccountNotifications.delivery_guard
        @notification = Object.new
        @payload = { "context" => { "event_id" => 12 } }
      end

      def teardown
        AccountNotifications.delivery_guard = @previous_guard
      end

      def test_unconfigured_host_keeps_existing_delivery
        AccountNotifications.delivery_guard = nil
        AccountNotifications.stub(:deliver_to_account, :accepted) do
          assert_equal :accepted, AccountNotifications.send(:deliver, @notification, @payload)
        end
      end

      def test_host_guard_can_veto_without_contacting_provider
        AccountNotifications.delivery_guard = lambda do |notification:, payload:, &block|
          assert_same @notification, notification
          assert_same @payload, payload
          assert block
          nil
        end
        AccountNotifications.stub(:deliver_to_account, ->(*) { flunk "provider must not be called" }) do
          assert_nil AccountNotifications.send(:deliver, @notification, @payload)
        end
      end

      def test_final_provider_call_runs_inside_host_guard
        guarded = false
        AccountNotifications.delivery_guard = lambda do |**_options, &block|
          guarded = true
          block.call
        ensure
          guarded = false
        end
        AccountNotifications.stub(:deliver_to_account, lambda { |*_args|
          assert guarded
          :accepted
        }) do
          assert_equal :accepted, AccountNotifications.send(:deliver, @notification, @payload)
        end
        assert_equal false, guarded
      end
    end
  end
end

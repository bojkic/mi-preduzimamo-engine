# frozen_string_literal: true

require "test_helper"
require "active_support/testing/time_helpers"
require "decidim/bih"
require_relative "../../../../../app/services/decidim/bih/viber/queued_phone_message_gateway"

module Decidim
  module Bih
    module Viber
      class QueuedPhoneMessageGatewayTest < Minitest::Test
        include ActiveSupport::Testing::TimeHelpers

        Client = Struct.new(:configured?)
        Job = Class.new

        def test_configured_requires_credentials_and_the_mandatory_sms_sender
          with_infobip_config(sms_sender: "MI") do
            assert QueuedPhoneMessageGateway.new(client: Client.new(true), job: Job, expires_in: 10.minutes).configured?
            refute QueuedPhoneMessageGateway.new(client: Client.new(false), job: Job, expires_in: 10.minutes).configured?
          end

          [nil, "", "   "].each do |sender|
            with_infobip_config(sms_sender: sender) do
              refute QueuedPhoneMessageGateway.new(client: Client.new(true), job: Job, expires_in: 10.minutes).configured?
            end
          end
        end

        def test_enqueue_uses_one_absolute_otp_deadline_for_job_and_durable_effect
          captured = nil
          enqueue = lambda do |job, **arguments|
            captured = { job:, arguments: }
            :deferred
          end
          gateway = QueuedPhoneMessageGateway.new(client: Client.new(true), job: Job, expires_in: 10.minutes)

          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            Decidim::Bih::DurableEffects.stub(:enqueue, enqueue) do
              assert_equal :deferred, gateway.send_sms(
                to: "38765123456",
                text: "Kod: 123456",
                channels: [:sms],
                otp_code: "123456"
              )
            end

            assert_equal Job, captured.fetch(:job)
            assert_equal "123456", captured.dig(:arguments, :otp_code)
            assert_equal [:sms], captured.dig(:arguments, :channels)
            assert_equal 10.minutes.from_now, captured.dig(:arguments, :expires_at)
            assert_same captured.dig(:arguments, :expires_at), captured.dig(:arguments, :effect_expires_at)
          end
        end

        private

        def with_infobip_config(sms_sender:)
          Decidim::Bih::Config.stub(:infobip, { sms_sender: }) { yield }
        end
      end
    end
  end
end

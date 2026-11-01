# frozen_string_literal: true

require_relative "../durable_effects"

module Decidim
  module Bih
    module Viber
      # AccountLinking adapter that keeps its historical #send_sms interface but
      # enqueues the shared ordered phone-delivery job. The OTP therefore uses
      # Viber Business Messages -> WhatsApp AUTH -> SMS where those channels
      # are configured and addressable.
      class QueuedPhoneMessageGateway
        def initialize(client: Decidim::Bih::Infobip::Client.new,
                       job: Decidim::Bih::Infobip::SendPhoneMessageJob,
                       expires_in: OtpStore::DEFAULT_TTL.seconds)
          @client = client
          @job = job
          @expires_in = expires_in
        end

        def configured?
          client.configured? && Decidim::Bih::Config.infobip[:sms_sender].present?
        end

        def send_sms(to:, text:, viber_template: nil, channels: nil, otp_code: nil)
          deadline = Time.current + expires_in
          Decidim::Bih::DurableEffects.enqueue(
            job,
            to:,
            text:,
            viber_template:,
            channels:,
            otp_code:,
            expires_at: deadline,
            effect_expires_at: deadline
          )
        rescue StandardError => e
          raise Decidim::Bih::Infobip::Error,
                "OTP phone-delivery enqueue failed: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end

        private

        attr_reader :client, :job, :expires_in
      end
    end
  end
end

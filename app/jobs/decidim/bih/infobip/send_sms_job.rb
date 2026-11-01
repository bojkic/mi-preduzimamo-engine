# frozen_string_literal: true

module Decidim
  module Bih
    module Infobip
      # Sends SMS via Infobip outside request/webhook paths. OTP callers pass an
      # expiry time so queue backlog or retries cannot deliver a stale code.
      class SendSmsJob < Decidim::ApplicationJob
        self.log_arguments = false

        queue_as :integrations

        retry_on Decidim::Bih::Infobip::Error,
                 wait: :polynomially_longer,
                 attempts: 5 do |job, error|
          args = job.arguments.first || {}
          to = args[:to] || args["to"]

          Rails.logger.error(
            "[Infobip::SendSmsJob] SMS exhausted for " \
            "#{Decidim::Bih::LogRedactor.mask_identifier(to)}: " \
            "#{Decidim::Bih::LogRedactor.error_message(error)}"
          )
        end
        discard_on ActiveJob::DeserializationError

        def perform(to:, text:, expires_at: nil)
          return if to.blank? || text.blank?

          if expired?(expires_at)
            Rails.logger.warn(
              "[Infobip::SendSmsJob] stale SMS dropped for " \
              "#{Decidim::Bih::LogRedactor.mask_identifier(to)}"
            )
            return
          end

          client = Decidim::Bih::Infobip::Client.new
          unless client.configured?
            Rails.logger.warn(
              "[Infobip::SendSmsJob] Infobip unconfigured; SMS not sent to " \
              "#{Decidim::Bih::LogRedactor.mask_identifier(to)}"
            )
            return
          end

          client.send_sms(to: to, text: text)
        end

        private

        def expired?(expires_at)
          return false if expires_at.blank?

          expires_at.to_time <= Time.current
        end
      end
    end
  end
end

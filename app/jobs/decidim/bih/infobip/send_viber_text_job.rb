# frozen_string_literal: true

require "time"
require_relative "../../../../services/decidim/bih/infobip/encrypted_job_envelope"

module Decidim
  module Bih
    module Infobip
      # Delivers a time-bounded Viber Bot reply. Public callers keep the
      # established keyword API, but ActiveJob receives only authenticated
      # ciphertext so Redis/retry/dead metadata cannot expose the opaque user
      # id or citizen-facing reply.
      class SendViberTextJob < Decidim::ApplicationJob
        self.log_arguments = false
        self.enqueue_after_transaction_commit = :always

        queue_as :integrations

        SESSION_REPLY_TTL = 23.hours
        ENCRYPTION_PURPOSE = "infobip-viber-bot-session-reply"
        ENCRYPTION_SALT = "decidim-bih-infobip-viber-bot-session-reply"
        MAX_IDENTIFIER_BYTES = 255
        MAX_REPLY_TEXT_LENGTH = 4000
        MAX_REPLY_TEXT_BYTES = MAX_REPLY_TEXT_LENGTH * 4
        MAX_STICKER_BYTES = 64

        before_enqueue :seal_enqueue_arguments!

        retry_on Decidim::Bih::Infobip::Error,
                 wait: :polynomially_longer,
                 attempts: 5 do |_job, error|
          log_exhausted_delivery(error)
        end
        discard_on ActiveJob::DeserializationError
        discard_on ActiveSupport::MessageEncryptor::InvalidMessage

        class << self
          def log_exhausted_delivery(error)
            Rails.logger.error(
              "[Infobip::SendViberTextJob] channel=viber " \
              "status=#{error.http_status || "unknown"} code=#{error.error_code || "unknown"} " \
              "group=#{error.error_group || "unknown"}"
            )
          end

          private

          def build_envelope(organization_id:, to:, text:, sticker:, expires_at:, base_time: Time.current) # rubocop:disable Metrics/ParameterLists
            {
              "organization_id" => positive_integer!(organization_id),
              "to" => bounded_identifier!(to, "recipient"),
              "text" => bounded_text!(text),
              "sticker" => bounded_optional_identifier(sticker, MAX_STICKER_BYTES, "sticker"),
              "expires_at" => bounded_expiry(expires_at, base_time:).iso8601(6)
            }.compact
          end

          def encrypt_envelope(envelope)
            EncryptedJobEnvelope.seal(envelope, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def decrypt_envelope(ciphertext)
            EncryptedJobEnvelope.open(ciphertext, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def positive_integer!(value)
            integer = Integer(value)
            raise Error, "Viber reply organization is invalid" unless integer.positive?

            integer
          rescue ArgumentError, TypeError
            raise Error, "Viber reply organization is invalid"
          end

          def bounded_identifier!(value, label)
            bounded_optional_identifier(value, MAX_IDENTIFIER_BYTES, label) ||
              raise(Error, "Viber reply #{label} is invalid")
          end

          def bounded_optional_identifier(value, limit, label)
            return if value.blank?

            string = value.to_s
            raise Error, "Viber reply #{label} is invalid" if string.bytesize > limit

            string
          end

          def bounded_text!(value)
            string = value.to_s
            raise Error, "Viber reply text is blank" if string.strip.empty?

            string = string.each_char.first(MAX_REPLY_TEXT_LENGTH).join
            return string if string.bytesize <= MAX_REPLY_TEXT_BYTES

            string.byteslice(0, MAX_REPLY_TEXT_BYTES).to_s.scrub("")
          end

          def bounded_expiry(value, base_time:)
            base = base_time.to_time
            latest = SESSION_REPLY_TTL.from_now(base)
            return latest if value.nil?

            requested = value.is_a?(String) ? Time.iso8601(value) : value.to_time
            return base if requested <= base

            [requested, latest].min
          rescue ArgumentError, TypeError, NoMethodError
            raise Error, "Viber reply expiry is invalid"
          end
        end

        # ActiveJob::ConfiguredJob (`.set(wait:).perform_later`) bypasses class
        # perform_later overrides. Sealing in the enqueue callback protects both
        # direct and configured scheduling; serialize is a defense for bulk
        # adapters that intentionally skip enqueue callbacks.
        def serialize
          seal_enqueue_arguments!
          super
        end

        # Plain keyword arguments remain accepted by perform_now and drain any
        # jobs enqueued by the previous release. Newly enqueued jobs always use
        # encrypted_payload.
        def perform(encrypted_payload: nil, organization_id: nil, to: nil, text: nil, sticker: nil, expires_at: nil) # rubocop:disable Metrics/ParameterLists
          envelope = if encrypted_payload.present?
                       self.class.send(:decrypt_envelope, encrypted_payload)
                     else
                       legacy_envelope(organization_id:, to:, text:, sticker:, expires_at:)
                     end
          if expired?(envelope["expires_at"])
            Rails.logger.warn("[Infobip::SendViberTextJob] channel=viber expired session reply dropped")
            return
          end

          client = Decidim::Bih::Infobip::Client.new
          # Switched off is a deliberate state, not a misconfiguration: this
          # deployment runs Viber Business Messages only, so drop the reply
          # quietly rather than raising a production alarm on every message.
          unless Decidim::Bih::Config.viber_bot_enabled?
            Rails.logger.info("[Infobip::SendViberTextJob] Viber Bot disabled; reply not sent")
            return
          end

          unless client.viber_bot_configured?
            raise Error, "Infobip Viber Bot configuration is incomplete" if Rails.env.production?

            Rails.logger.info("[Infobip::SendViberTextJob] Viber Bot unconfigured; reply not sent")
            return
          end

          safely_send(client, envelope)
          enqueue_sticker(envelope)
        end

        private

        def seal_enqueue_arguments!
          send(:deserialize_arguments_if_needed)
          return if encrypted_enqueue_arguments?

          attributes = enqueue_attributes!
          envelope = self.class.send(
            :build_envelope,
            organization_id: argument_value(attributes, :organization_id),
            to: argument_value(attributes, :to),
            text: argument_value(attributes, :text),
            sticker: argument_value(attributes, :sticker),
            expires_at: argument_value(attributes, :expires_at),
            base_time: Time.current
          )
          ciphertext = self.class.send(:encrypt_envelope, envelope)
          self.arguments = [Hash.ruby2_keywords_hash({ encrypted_payload: ciphertext })]
        end

        def encrypted_enqueue_arguments?
          return false unless arguments.one? && arguments.first.respond_to?(:keys)

          attributes = arguments.first
          attributes.keys.map(&:to_s) == ["encrypted_payload"] &&
            argument_value(attributes, :encrypted_payload).present?
        end

        def enqueue_attributes!
          attributes = arguments.first
          return attributes if arguments.one? && attributes.respond_to?(:keys)

          raise Error, "Viber reply job arguments are invalid"
        end

        def argument_value(attributes, key)
          return attributes[key] if attributes.has_key?(key)

          attributes[key.to_s]
        end

        def legacy_envelope(organization_id:, to:, text:, sticker:, expires_at:)
          self.class.send(
            :build_envelope,
            organization_id:,
            to:,
            text:,
            sticker:,
            expires_at: expires_at || legacy_deadline,
            base_time: legacy_base_time
          )
        end

        def legacy_deadline
          SESSION_REPLY_TTL.from_now(legacy_base_time)
        end

        def legacy_base_time
          respond_to?(:enqueued_at) && enqueued_at ? enqueued_at.to_time : Time.current
        end

        def expired?(value)
          Time.iso8601(value.to_s) <= Time.current
        rescue ArgumentError, TypeError
          true
        end

        def safely_send(client, envelope)
          client.send_viber_bot(to: envelope.fetch("to"), text: envelope.fetch("text"))
        rescue Error => e
          raise Error.new("Infobip Viber Bot delivery failed", **e.metadata), cause: nil
        end

        def enqueue_sticker(envelope)
          sticker = envelope["sticker"]
          return if sticker.blank?

          Decidim::Bih::Infobip::SendViberImageJob.perform_later(
            organization_id: envelope.fetch("organization_id"),
            to: envelope.fetch("to"),
            sticker:,
            expires_at: envelope.fetch("expires_at")
          )
        rescue StandardError => e
          # Text has already been accepted by Infobip. A decorative sticker is
          # best-effort and must never make ActiveJob retry/resend that text.
          Rails.logger.warn("[Infobip::SendViberTextJob] sticker enqueue failed class=#{e.class}")
        end
      end
    end
  end
end

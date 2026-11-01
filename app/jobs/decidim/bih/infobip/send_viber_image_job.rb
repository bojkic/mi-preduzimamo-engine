# frozen_string_literal: true

require "time"
require_relative "../../../../services/decidim/bih/infobip/encrypted_job_envelope"

module Decidim
  module Bih
    module Infobip
      # Best-effort Viber sticker delivery. Like the text job, its ActiveJob
      # payload is an authenticated ciphertext with the original reply deadline.
      class SendViberImageJob < Decidim::ApplicationJob
        self.log_arguments = false
        self.enqueue_after_transaction_commit = :always

        queue_as :integrations

        SESSION_REPLY_TTL = 23.hours
        ENCRYPTION_PURPOSE = "infobip-viber-bot-session-sticker"
        ENCRYPTION_SALT = "decidim-bih-infobip-viber-bot-session-sticker"
        MAX_IDENTIFIER_BYTES = 255
        MAX_STICKER_BYTES = 64

        before_enqueue :seal_enqueue_arguments!

        discard_on ActiveJob::DeserializationError
        discard_on ActiveSupport::MessageEncryptor::InvalidMessage

        class << self
          def build_envelope(organization_id:, to:, sticker:, expires_at:, base_time: Time.current)
            {
              "organization_id" => positive_integer!(organization_id),
              "to" => bounded_identifier!(to, MAX_IDENTIFIER_BYTES, "recipient"),
              "sticker" => bounded_identifier!(sticker, MAX_STICKER_BYTES, "sticker"),
              "expires_at" => bounded_expiry(expires_at, base_time:).iso8601(6)
            }
          end

          private

          def encrypt_envelope(envelope)
            EncryptedJobEnvelope.seal(envelope, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def decrypt_envelope(ciphertext)
            EncryptedJobEnvelope.open(ciphertext, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def positive_integer!(value)
            integer = Integer(value)
            raise Error, "Viber sticker organization is invalid" unless integer.positive?

            integer
          rescue ArgumentError, TypeError
            raise Error, "Viber sticker organization is invalid"
          end

          def bounded_identifier!(value, limit, label)
            string = value.to_s
            raise Error, "Viber sticker #{label} is invalid" if string.strip.empty? || string.bytesize > limit

            string
          end

          def bounded_expiry(value, base_time:)
            base = base_time.to_time
            latest = SESSION_REPLY_TTL.from_now(base)
            return latest if value.nil?

            requested = value.is_a?(String) ? Time.iso8601(value) : value.to_time
            return base if requested <= base

            [requested, latest].min
          rescue ArgumentError, TypeError, NoMethodError
            raise Error, "Viber sticker expiry is invalid"
          end
        end

        def serialize
          seal_enqueue_arguments!
          super
        end

        def perform(encrypted_payload: nil, organization_id: nil, to: nil, sticker: nil, expires_at: nil)
          envelope = delivery_envelope(encrypted_payload:, organization_id:, to:, sticker:, expires_at:)
          if expired?(envelope["expires_at"])
            Rails.logger.warn("[Infobip::SendViberImageJob] channel=viber expired session sticker dropped")
            return
          end

          deliver_image(envelope)
        rescue Error => e
          Rails.logger.warn(
            "[Infobip::SendViberImageJob] channel=viber status=#{e.http_status || "unknown"} " \
            "code=#{e.error_code || "unknown"} group=#{e.error_group || "unknown"}"
          )
        end

        private

        def delivery_envelope(encrypted_payload:, organization_id:, to:, sticker:, expires_at:)
          return self.class.send(:decrypt_envelope, encrypted_payload) if encrypted_payload.present?

          legacy_envelope(organization_id:, to:, sticker:, expires_at:)
        end

        def deliver_image(envelope)
          organization = organization_for(envelope.fetch("organization_id"))
          return if organization.nil?

          # Viber Bots accepts GIF only as a non-animated image and applies a
          # strict image-size ceiling. Persona gestures therefore use the
          # provider-safe static rendition; legacy PNG stickers are unchanged.
          image_url = Decidim::Bih::Concierge::Stickers.url_for(
            envelope.fetch("sticker"),
            organization:,
            variant: :static
          )
          return if image_url.blank?

          client = Decidim::Bih::Infobip::Client.new
          unless client.viber_bot_active?
            Rails.logger.info("[Infobip::SendViberImageJob] Viber Bot inactive; sticker not sent")
            return
          end

          client.send_viber_bot_image(to: envelope.fetch("to"), image_url:)
        end

        def organization_for(id)
          Decidim::Organization.find_by(id:)
        end

        def seal_enqueue_arguments!
          send(:deserialize_arguments_if_needed)
          return if encrypted_enqueue_arguments?

          attributes = enqueue_attributes!
          envelope = self.class.send(
            :build_envelope,
            organization_id: argument_value(attributes, :organization_id),
            to: argument_value(attributes, :to),
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

          raise Error, "Viber sticker job arguments are invalid"
        end

        def argument_value(attributes, key)
          return attributes[key] if attributes.has_key?(key)

          attributes[key.to_s]
        end

        def legacy_envelope(organization_id:, to:, sticker:, expires_at:)
          self.class.send(
            :build_envelope,
            organization_id:,
            to:,
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
      end
    end
  end
end

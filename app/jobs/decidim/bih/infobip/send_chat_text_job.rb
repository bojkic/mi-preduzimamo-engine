# frozen_string_literal: true

require "time"
require_relative "../../../../services/decidim/bih/infobip/bounded_chat_text"
require_relative "../../../../services/decidim/bih/infobip/encrypted_job_envelope"

module Decidim
  module Bih
    module Infobip
      # Delivers an immediate text reply to a citizen-initiated WhatsApp,
      # Messenger or Instagram session. The deadline is stamped when the job is
      # enqueued, so retries cannot turn a session reply into a late proactive
      # message outside the channel's free-form automation window.
      class SendChatTextJob < Decidim::ApplicationJob
        self.log_arguments = false
        self.enqueue_after_transaction_commit = :always

        queue_as :integrations

        SESSION_REPLY_TTL = 23.hours
        ENCRYPTION_PURPOSE = "infobip-chat-session-reply"
        ENCRYPTION_SALT = "decidim-bih-infobip-chat-session-reply"
        MAX_REPLY_TEXT_BYTES = BoundedChatText::MAX_BYTES
        MAX_IDENTIFIER_BYTES = 255
        MAX_MEDIA_ID_BYTES = 64

        before_enqueue :seal_enqueue_arguments!

        retry_on Decidim::Bih::Infobip::Error,
                 wait: :polynomially_longer,
                 attempts: 5 do |job, error|
          log_exhausted_delivery(job, error)
        end
        discard_on ActiveJob::DeserializationError
        discard_on ActiveSupport::MessageEncryptor::InvalidMessage

        class << self
          def log_exhausted_delivery(job, error)
            args = job.arguments.first || {}
            encrypted_payload = args[:encrypted_payload] || args["encrypted_payload"]
            channel = channel_from_envelope(encrypted_payload)

            Rails.logger.error(
              "[Infobip::SendChatTextJob] channel=#{safe_channel(channel)} " \
              "status=#{error.http_status || "unknown"} code=#{error.error_code || "unknown"} " \
              "group=#{error.error_group || "unknown"}"
            )
          end

          private

          # rubocop:disable Metrics/ParameterLists
          def build_envelope(channel:, to:, text:, sender:, expires_at:, request_phone: false,
                             organization_id: nil, media_id: nil,
                             base_time: Time.current)
            normalized_channel = safe_channel(channel)
            raise Decidim::Bih::Infobip::Error, "Infobip chat channel is unsupported" if normalized_channel == "unsupported"

            {
              "channel" => normalized_channel,
              "to" => bounded_identifier!(to, "recipient"),
              "text" => bounded_text(text),
              "sender" => bounded_optional_identifier!(sender, "sender"),
              "request_phone" => bounded_phone_request(request_phone, channel: normalized_channel),
              "organization_id" => bounded_optional_organization_id(organization_id, media_id:),
              "media_id" => bounded_optional_media_id(media_id),
              "expires_at" => bounded_expiry(expires_at, base_time:).iso8601(6)
            }.compact
          end

          def encrypt_envelope(envelope)
            EncryptedJobEnvelope.seal(envelope, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def decrypt_envelope(encrypted_payload)
            EncryptedJobEnvelope.open(encrypted_payload, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def channel_from_envelope(encrypted_payload)
            safe_channel(decrypt_envelope(encrypted_payload)["channel"])
          rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError, TypeError
            "unsupported"
          end

          def bounded_identifier!(value, label)
            string = value.to_s
            raise Decidim::Bih::Infobip::Error, "Infobip chat #{label} is invalid" if string.strip.empty? || string.bytesize > MAX_IDENTIFIER_BYTES

            string
          end

          def bounded_optional_identifier!(value, label)
            return if value.blank?

            bounded_identifier!(value, label)
          end

          def bounded_optional_media_id(value)
            return if value.blank?

            string = value.to_s
            raise Decidim::Bih::Infobip::Error, "Infobip chat media id is invalid" unless
              string.match?(/\A[a-z0-9_]+\z/) && string.bytesize <= MAX_MEDIA_ID_BYTES

            string
          end

          def bounded_optional_organization_id(value, media_id:)
            return if media_id.blank? && value.blank?

            integer = Integer(value)
            raise Decidim::Bih::Infobip::Error, "Infobip chat organization is invalid" unless integer.positive?

            integer
          rescue ArgumentError, TypeError
            raise Decidim::Bih::Infobip::Error, "Infobip chat organization is invalid"
          end

          def bounded_text(value)
            string = value.to_s
            raise Decidim::Bih::Infobip::Error, "Infobip chat reply text is blank" if string.strip.empty?

            return string if string.bytesize <= MAX_REPLY_TEXT_BYTES

            BoundedChatText.call(string, max_bytes: MAX_REPLY_TEXT_BYTES)
          end

          def bounded_phone_request(value, channel:)
            value = false if value.nil?
            raise Decidim::Bih::Infobip::Error, "Infobip chat phone request must be boolean" unless [true, false].include?(value)
            raise Decidim::Bih::Infobip::Error, "Infobip chat phone request requires Messenger" if value && channel != "messenger"

            value
          end

          def bounded_expiry(value, base_time:)
            base = base_time.to_time
            latest = SESSION_REPLY_TTL.from_now(base)
            return latest if value.nil?

            requested = value.is_a?(String) ? Time.iso8601(value) : value.to_time
            return base if requested <= base

            [requested, latest].min
          rescue ArgumentError, TypeError, NoMethodError
            raise Decidim::Bih::Infobip::Error, "Infobip chat reply expiry is invalid"
          end

          def safe_channel(value)
            normalized = value.to_s.strip.downcase
            Decidim::Bih::Config::INFOBIP_CHAT_CHANNELS.include?(normalized) ? normalized : "unsupported"
          end
        end

        # Protect direct, ConfiguredJob and bulk scheduling before any queue
        # adapter sees the recipient/content. Plain perform keywords remain
        # accepted solely for direct execution and draining old queued jobs.
        def serialize
          seal_enqueue_arguments!
          super
        end

        def perform(encrypted_payload: nil, channel: nil, to: nil, text: nil, sender: nil,
                    request_phone: false, organization_id: nil, media_id: nil, expires_at: nil)
          envelope = if encrypted_payload.present?
                       self.class.send(:decrypt_envelope, encrypted_payload)
                     else
                       legacy_envelope(
                         channel:, to:, text:, sender:, request_phone:, organization_id:, media_id:, expires_at:
                       )
                     end
          channel = envelope["channel"]
          to = envelope["to"]
          text = envelope["text"]
          sender = envelope["sender"]
          expires_at = envelope["expires_at"]

          if expired?(expires_at)
            Rails.logger.warn(
              "[Infobip::SendChatTextJob] #{safe_channel(channel)} expired session reply dropped"
            )
            return
          end

          client = Decidim::Bih::Infobip::Client.new
          unless client.chat_channel_configured?(channel)
            if Rails.env.production? && enabled_channel?(channel)
              raise Decidim::Bih::Infobip::Error,
                    "#{safe_channel(channel)} chat configuration is incomplete"
            end

            Rails.logger.info(
              "[Infobip::SendChatTextJob] #{safe_channel(channel)} chat unconfigured; reply not sent"
            )
            return
          end

          client.send_chat_text(
            channel:, to:, text:, sender:, request_phone: envelope["request_phone"] == true
          )
          send_media_best_effort(client, envelope)
        end

        private

        def seal_enqueue_arguments!
          send(:deserialize_arguments_if_needed)
          return if encrypted_enqueue_arguments?

          attributes = enqueue_attributes!
          envelope = self.class.send(
            :build_envelope,
            channel: argument_value(attributes, :channel),
            to: argument_value(attributes, :to),
            text: argument_value(attributes, :text),
            sender: argument_value(attributes, :sender),
            request_phone: argument_value(attributes, :request_phone),
            organization_id: argument_value(attributes, :organization_id),
            media_id: argument_value(attributes, :media_id),
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

          raise Decidim::Bih::Infobip::Error, "Infobip chat reply job arguments are invalid"
        end

        def argument_value(attributes, key)
          return attributes[key] if attributes.has_key?(key)

          attributes[key.to_s]
        end

        def legacy_envelope(channel:, to:, text:, sender:, request_phone:, organization_id:, media_id:, expires_at:)
          self.class.send(
            :build_envelope,
            channel:,
            to:,
            text:,
            sender:,
            request_phone:,
            organization_id:,
            media_id:,
            expires_at: expires_at || legacy_deadline,
            base_time: legacy_base_time
          )
        end
        # rubocop:enable Metrics/ParameterLists

        def legacy_deadline
          SESSION_REPLY_TTL.from_now(legacy_base_time)
        end

        def legacy_base_time
          respond_to?(:enqueued_at) && enqueued_at ? enqueued_at.to_time : Time.current
        end

        def expired?(expires_at)
          return false if expires_at.blank?

          expiry = expires_at.is_a?(String) ? Time.iso8601(expires_at) : expires_at.to_time
          expiry <= Time.current
        rescue ArgumentError, TypeError
          true
        end

        def safe_channel(value)
          self.class.send(:safe_channel, value)
        end

        def enabled_channel?(value)
          Decidim::Bih::Config.infobip[:chat_channels].include?(safe_channel(value))
        end

        def send_media_best_effort(client, envelope)
          media_id = envelope["media_id"]
          return if media_id.blank?

          organization = organization_for(envelope["organization_id"])
          return if organization.nil?

          image_url = Decidim::Bih::Concierge::Stickers.url_for(
            media_id,
            organization:,
            variant: :static
          )
          return if image_url.blank?

          client.send_chat_image(
            channel: envelope.fetch("channel"),
            to: envelope.fetch("to"),
            image_url:,
            sender: envelope["sender"]
          )
        rescue Decidim::Bih::Infobip::Error => e
          # Text has already been accepted. Decorative media is best-effort and
          # must not cause a retry that duplicates the citizen-facing answer.
          Rails.logger.warn(
            "[Infobip::SendChatTextJob] channel=#{safe_channel(envelope["channel"])} " \
            "media_failed status=#{e.http_status || "unknown"} code=#{e.error_code || "unknown"} " \
            "group=#{e.error_group || "unknown"}"
          )
        rescue StandardError => e
          Rails.logger.warn(
            "[Infobip::SendChatTextJob] channel=#{safe_channel(envelope["channel"])} " \
            "media_failed class=#{e.class}"
          )
        end

        def organization_for(id)
          Decidim::Organization.find_by(id:)
        end
      end
    end
  end
end

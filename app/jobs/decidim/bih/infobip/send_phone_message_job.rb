# frozen_string_literal: true

require "time"
require_relative "../../../../services/decidim/bih/infobip/encrypted_job_envelope"
require_relative "../../../../services/decidim/bih/integration_health"

module Decidim
  module Bih
    module Infobip
      # Delivers a time-sensitive authentication message through the shared
      # Viber Business Messages -> WhatsApp AUTH -> SMS policy.
      # Queue adapters receive only purpose-isolated authenticated ciphertext;
      # phone numbers, OTPs, magic links and template parameters are decrypted
      # inside the worker after the caller's transaction commits.
      class SendPhoneMessageJob < Decidim::ApplicationJob
        self.log_arguments = false
        self.enqueue_after_transaction_commit = :always

        # Authentication capacity is RESERVED: this job leaves the shared
        # `integrations` queue so a campaign or city-alert backlog can never sit
        # in front of a sign-in code. The literal is deliberate rather than a
        # call into `Messaging::Priority` — a service failing to load must not
        # be able to stop an authentication message from being enqueued — and
        # the host's job-queue contract test pins the literal to
        # `Priority.queue_for_priority("authentication")` so the two cannot
        # drift apart.
        #
        # Reserving capacity relaxes nothing: the per-IP, per-session and
        # per-phone Rack::Attack throttles, the resend budget and the
        # wrong-code attempt limiter all run before anything reaches this queue.
        #
        # ⚠️ Deploy order: `config/sidekiq.yml` must already list
        # `authentication_critical` and Sidekiq must be restarted, or messages
        # enqueued here are never picked up.
        queue_as :authentication_critical

        AUTH_MESSAGE_TTL = 23.hours
        ENCRYPTION_PURPOSE = "infobip-phone-auth-message"
        ENCRYPTION_SALT = "decidim-bih-infobip-phone-auth-message"
        MAX_IDENTIFIER_BYTES = 255
        MAX_TEXT_BYTES = 16_000
        MAX_TEMPLATE_ID_BYTES = 255
        MAX_TEMPLATE_LANGUAGE_BYTES = 32
        MAX_TEMPLATE_PARAMETERS = 32
        MAX_TEMPLATE_PARAMETER_KEY_BYTES = 64
        MAX_TEMPLATE_PARAMETER_VALUE_BYTES = 4096
        MAX_OTP_CODE_BYTES = 64
        MAX_CHANNELS = 3
        MAX_CHANNEL_NAME_BYTES = 16

        before_enqueue :seal_enqueue_arguments!

        retry_on Decidim::Bih::Infobip::Error,
                 wait: :polynomially_longer,
                 attempts: 5 do |_job, error|
          log_exhausted_delivery(error)
        end
        discard_on ActiveJob::DeserializationError
        discard_on ActiveSupport::MessageEncryptor::InvalidMessage
        discard_on JSON::ParserError

        class << self
          def log_exhausted_delivery(error)
            Rails.logger.error(
              "[Infobip::SendPhoneMessageJob] channel=phone " \
              "status=#{error.http_status || "unknown"} code=#{error.error_code || "unknown"} " \
              "group=#{error.error_group || "unknown"}"
            )
          end

          private

          def build_envelope(to:, text:, viber_text:, viber_template:, expires_at:, messenger:, channels:, otp_code:, base_time: Time.current) # rubocop:disable Metrics/ParameterLists
            {
              "to" => bounded_required_text!(to, MAX_IDENTIFIER_BYTES, "recipient"),
              "text" => bounded_required_text!(text, MAX_TEXT_BYTES, "text"),
              "viber_text" => bounded_optional_text!(viber_text, MAX_TEXT_BYTES, "Viber text"),
              "viber_template" => bounded_template(viber_template),
              "expires_at" => bounded_expiry(expires_at, base_time:).iso8601(6),
              "messenger" => bounded_messenger(messenger),
              "channels" => bounded_channels(channels),
              "otp_code" => bounded_optional_text!(otp_code, MAX_OTP_CODE_BYTES, "OTP code")
            }.compact
          end

          def bounded_channels(value)
            return if value.nil?
            raise Error, "Infobip phone channel subset is invalid" unless value.is_a?(Array)
            raise Error, "Infobip phone channel subset is invalid" if value.empty? || value.size > MAX_CHANNELS

            value.map do |channel|
              bounded_required_text!(channel, MAX_CHANNEL_NAME_BYTES, "phone channel")
            end
          rescue NoMethodError, TypeError
            raise Error, "Infobip phone channel subset is invalid"
          end

          def encrypt_envelope(envelope)
            EncryptedJobEnvelope.seal(envelope, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def decrypt_envelope(ciphertext)
            EncryptedJobEnvelope.open(ciphertext, purpose: ENCRYPTION_PURPOSE, salt: ENCRYPTION_SALT)
          end

          def bounded_template(value)
            return if value.blank?

            template = value.to_h
            {
              "template_id" => bounded_required_text!(hash_value(template, :template_id), MAX_TEMPLATE_ID_BYTES, "template id"),
              "language" => bounded_optional_text!(hash_value(template, :language), MAX_TEMPLATE_LANGUAGE_BYTES, "template language"),
              "parameters" => bounded_template_parameters(hash_value(template, :parameters))
            }.compact
          rescue NoMethodError, TypeError
            raise Error, "Infobip phone template is invalid"
          end

          def bounded_template_parameters(value)
            return {} if value.nil?

            parameters = value.to_h
            raise Error, "Infobip phone template parameters are invalid" if parameters.size > MAX_TEMPLATE_PARAMETERS

            parameters.to_h do |key, parameter_value|
              [
                bounded_required_text!(key, MAX_TEMPLATE_PARAMETER_KEY_BYTES, "template parameter key"),
                bounded_required_text!(parameter_value, MAX_TEMPLATE_PARAMETER_VALUE_BYTES, "template parameter value")
              ]
            end
          rescue NoMethodError, TypeError
            raise Error, "Infobip phone template parameters are invalid"
          end

          def bounded_messenger(value)
            return if value.blank?

            messenger = value.to_h
            {
              "to" => bounded_optional_text!(hash_value(messenger, :to), MAX_IDENTIFIER_BYTES, "Messenger recipient"),
              "session_active" => hash_value(messenger, :session_active) == true
            }.compact
          rescue NoMethodError, TypeError
            raise Error, "Infobip phone Messenger session is invalid"
          end

          def bounded_required_text!(value, limit, label)
            string = value.to_s
            raise Error, "Infobip phone #{label} is invalid" if string.strip.empty? || string.bytesize > limit

            string
          end

          def bounded_optional_text!(value, limit, label)
            return if value.blank?

            bounded_required_text!(value, limit, label)
          end

          def bounded_expiry(value, base_time:)
            base = base_time.to_time
            latest = AUTH_MESSAGE_TTL.from_now(base)
            return latest if value.nil?

            requested = value.is_a?(String) ? Time.iso8601(value) : value.to_time
            return base if requested <= base

            [requested, latest].min
          rescue ArgumentError, TypeError, NoMethodError
            raise Error, "Infobip phone message expiry is invalid"
          end

          def hash_value(hash, key)
            hash[key] || hash[key.to_s]
          end
        end

        # ConfiguredJob scheduling bypasses class perform_later overrides.
        # Encrypt in the enqueue callback, with serialize as a bulk-adapter
        # defense, before any adapter can persist authentication secrets.
        def serialize
          seal_enqueue_arguments!
          super
        end

        # Plain keywords remain accepted only for perform_now and draining jobs
        # created by an earlier release. Every new enqueue uses encrypted_payload.
        def perform(encrypted_payload: nil, to: nil, text: nil, viber_text: nil, viber_template: nil, # rubocop:disable Metrics/ParameterLists
                    expires_at: nil, messenger: nil, channels: nil, otp_code: nil)
          envelope = if encrypted_payload.present?
                       self.class.send(:decrypt_envelope, encrypted_payload)
                     else
                       legacy_envelope(to:, text:, viber_text:, viber_template:, expires_at:, messenger:, channels:, otp_code:)
                     end

          if expired?(envelope.fetch("expires_at"))
            Rails.logger.warn("[Infobip::SendPhoneMessageJob] channel=phone stale authentication message dropped")
            return
          end

          client = Decidim::Bih::Infobip::Client.new
          unless client.configured?
            Decidim::Bih::IntegrationHealth.instance.record(
              "decidim_bih.infobip.request",
              provider: "infobip",
              success: false,
              error_code: "unconfigured",
              error_class: "ConfigurationError"
            )
            Rails.logger.warn("[Infobip::SendPhoneMessageJob] channel=phone Infobip unconfigured; message not sent")
            raise Error, "Infobip phone delivery configuration is incomplete" if Rails.env.production?

            return
          end

          safely_send(client, envelope)
        end

        private

        def seal_enqueue_arguments!
          send(:deserialize_arguments_if_needed)
          return if encrypted_enqueue_arguments?

          attributes = enqueue_attributes!
          envelope = self.class.send(
            :build_envelope,
            to: argument_value(attributes, :to),
            text: argument_value(attributes, :text),
            viber_text: argument_value(attributes, :viber_text),
            viber_template: argument_value(attributes, :viber_template),
            expires_at: argument_value(attributes, :expires_at),
            messenger: argument_value(attributes, :messenger),
            channels: argument_value(attributes, :channels),
            otp_code: argument_value(attributes, :otp_code),
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

          raise Error, "Infobip phone message job arguments are invalid"
        end

        def argument_value(attributes, key)
          return attributes[key] if attributes.has_key?(key)

          attributes[key.to_s]
        end

        def legacy_envelope(to:, text:, viber_text:, viber_template:, expires_at:, messenger:, channels:, otp_code:) # rubocop:disable Metrics/ParameterLists
          self.class.send(
            :build_envelope,
            to:,
            text:,
            viber_text:,
            viber_template:,
            expires_at: expires_at || legacy_deadline,
            messenger:,
            channels:,
            otp_code:,
            base_time: legacy_base_time
          )
        end

        def legacy_deadline
          AUTH_MESSAGE_TTL.from_now(legacy_base_time)
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
          client.send_phone_message(
            to: envelope.fetch("to"),
            text: envelope.fetch("text"),
            viber_text: envelope["viber_text"],
            viber_template: template_for_client(envelope["viber_template"]),
            expires_at: Time.iso8601(envelope.fetch("expires_at")),
            messenger: messenger_for_client(envelope["messenger"]),
            channels: channels_for_client(envelope["channels"]),
            otp_code: envelope["otp_code"]
          )
        rescue Error => e
          raise Error.new("Infobip phone delivery failed", **e.metadata), cause: nil
        end

        def template_for_client(template)
          return if template.blank?

          {
            template_id: template["template_id"],
            language: template["language"],
            parameters: template["parameters"] || {}
          }.compact
        end

        def messenger_for_client(messenger)
          return if messenger.blank?

          {
            to: messenger["to"],
            session_active: messenger["session_active"] == true
          }.compact
        end

        def channels_for_client(channels)
          return if channels.blank?

          channels.map(&:to_sym)
        end
      end
    end
  end
end

# frozen_string_literal: true

require "decidim/bih/redaction"

module Decidim
  module Bih
    # Sanitizes exception metadata that is safe to persist for operators.
    # It preserves the operational shape of a failure while removing contact
    # details, URLs, credentials and report-payload fields.
    #
    # The regex primitives are shared with Decidim::Bih::LogRedactor via
    # Decidim::Bih::Redaction so the two cannot drift; this module differs only
    # in *presentation* (wholesale [phone]/[email]/[url], collapsed whitespace,
    # no truncation ellipsis) and in scrubbing report-payload fields.
    module SafeErrorMetadata
      # Re-exported from the shared core so direct constant references keep
      # resolving and there is a single canonical definition.
      EMAIL_PATTERN = Decidim::Bih::Redaction::EMAIL_PATTERN
      PHONE_PATTERN = Decidim::Bih::Redaction::PHONE_PATTERN
      URL_PATTERN = Decidim::Bih::Redaction::URL_PATTERN
      SENSITIVE_ASSIGNMENT = Decidim::Bih::Redaction::SENSITIVE_ASSIGNMENT
      FORWARDING_PAYLOAD_FIELDS = %w(
        address description lat latitude lng longitude photo_url reporter_contact
        reporter_email reporter_phone
      ).freeze

      module_function

      def error_class(error, max: 120)
        truncate(error.class.name.to_s, max:)
      end

      def error_code(error, explicit: nil, max: 80)
        raw = explicit || error_code_from(error)
        sanitized = sanitize_text(raw, max:)
        sanitized.empty? ? nil : sanitized
      end

      def error_message(error, fallback: "Forwarding failed", max: 240)
        raw = error.respond_to?(:message) ? error.message : error
        sanitized = sanitize_text(raw, max:)
        sanitized.empty? ? fallback : sanitized
      end

      def sanitize_text(value, max: 240)
        text = value.to_s.dup
        text.gsub!(URL_PATTERN, "[url]")
        text.gsub!(EMAIL_PATTERN, "[email]")
        text.gsub!(PHONE_PATTERN, "[phone]")
        text.gsub!(SENSITIVE_ASSIGNMENT) { "#{Regexp.last_match(1)}[redacted]" }

        FORWARDING_PAYLOAD_FIELDS.each do |field|
          text.gsub!(payload_field_pattern(field)) { "#{Regexp.last_match(1)}[redacted]" }
        end

        truncate(text.split.join(" "), max:)
      end

      def truncate(value, max:)
        return value if value.length <= max

        value[0, max]
      end

      def error_code_from(error)
        [:code, :error_code, :status].each do |method_name|
          return error.public_send(method_name) if error.respond_to?(method_name)
        end

        nil
      end

      def payload_field_pattern(field)
        Decidim::Bih::Redaction.payload_field_pattern(field)
      end
    end
  end
end

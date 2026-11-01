# frozen_string_literal: true

require "decidim/bih/redaction"

module Decidim
  module Bih
    # Small, dependency-free helpers for values that may end up in logs or
    # exception messages. The goal is to preserve operational shape while
    # removing secrets, OTPs, signed URLs, and full phone numbers.
    #
    # The regex primitives are shared with Decidim::Bih::SafeErrorMetadata via
    # Decidim::Bih::Redaction so the two cannot drift; this module differs only
    # in *presentation* (last-4 phone mask, host-preserving URL redaction,
    # OTP scrubbing, [REDACTED] casing, truncation ellipsis).
    module LogRedactor
      module_function

      # Re-exported from the shared core so direct constant references keep
      # resolving and there is a single canonical definition.
      PHONE_PATTERN = Decidim::Bih::Redaction::PHONE_PATTERN
      OTP_PATTERN = Decidim::Bih::Redaction::OTP_PATTERN
      EMAIL_PATTERN = Decidim::Bih::Redaction::EMAIL_PATTERN
      SENSITIVE_ASSIGNMENT = Decidim::Bih::Redaction::SENSITIVE_ASSIGNMENT
      URL_PATTERN = Decidim::Bih::Redaction::URL_PATTERN

      # A database uniqueness violation reduced to the only two things a log
      # line may carry: the exception class and the index or constraint that
      # refused. PostgreSQL puts the colliding VALUES in the message itself
      # ("DETAIL: Key (email, decidim_organization_id)=(mila@example.org, 1)
      # already exists"), so the message never goes to the log — not even
      # sanitized, because the shape of what it carries depends on which index
      # was hit.
      CONSTRAINT_NAME = /(?:constraint|index)\s+"([^"]+)"/i

      # The address rule is applied BEFORE the phone one: a local part can end
      # in a long run of digits, and masking that first would leave the domain
      # behind as though the address had been handled.
      def sanitize(value, max: 300)
        text = value.to_s.dup
        text.gsub!(URL_PATTERN) { |url| sanitize_url(url) }
        text.gsub!(EMAIL_PATTERN, "[email]")
        text.gsub!(SENSITIVE_ASSIGNMENT) { "#{Regexp.last_match(1)}[REDACTED]" }
        text.gsub!(PHONE_PATTERN) { |phone| mask_phone(phone) }
        text.gsub!(OTP_PATTERN, "[OTP]")
        truncate(text, max:)
      end

      # Never takes the message, only the index name out of it.
      def constraint_violation(error)
        message = error.respond_to?(:message) ? error.message.to_s : ""
        name = message[CONSTRAINT_NAME, 1]
        name ? "#{error.class} on #{name}" : error.class.to_s
      end

      def provider_response(value, max: 300)
        sanitized = sanitize(value, max:)
        sanitized.presence || "empty response"
      end

      def error_message(error, max: 300)
        sanitize(error.respond_to?(:message) ? error.message : error, max:)
      end

      def mask_phone(value)
        Decidim::Bih::Redaction.mask_phone(value)
      end

      def mask_identifier(value)
        text = value.to_s
        return "[identifier]" if text.blank?

        digits = text.gsub(/\D/, "")
        return mask_phone(text) if digits.length >= 8

        "[identifier:***#{text.last(4)}]"
      end

      def sanitize_url(value)
        Decidim::Bih::Redaction.redact_url_query(value)
      end

      def truncate(value, max:)
        return value if value.length <= max

        "#{value[0, max]}..."
      end
    end
  end
end

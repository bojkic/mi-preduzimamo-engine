# frozen_string_literal: true

require "uri"

module Decidim
  module Bih
    # Single source of truth for the PII/secret redaction primitives shared by
    # +Decidim::Bih::LogRedactor+ (operational logs) and
    # +Decidim::Bih::SafeErrorMetadata+ (persisted exception metadata).
    #
    # The two consumers legitimately differ in *presentation* — log lines keep
    # operational shape (last-4 of a phone, host of a URL) while persisted
    # metadata wipes contact data wholesale ([phone]/[email]/[url]) — but they
    # MUST agree on *what* counts as sensitive. Owning the regexes here keeps
    # them from drifting (which is exactly how a recent fix had to patch one
    # pattern the other already had).
    #
    # This module lives under +lib+ (not +app/services+) because
    # +safe_error_metadata+ requires it at boot, before Zeitwerk autoloading of
    # +app+ is active.
    module Redaction
      module_function

      # A run of 8-15 digits, optionally prefixed with "+" and interspersed with
      # spaces/dashes/slashes/parens/dots, not glued to a word character on
      # either side. Matches international and local phone numbers.
      PHONE_PATTERN = %r{(?<!\w)\+?(?:\d[\s\-/().]*){8,15}(?!\w)}

      # A bare 6-digit run (typical OTP), not part of a longer number.
      OTP_PATTERN = /(?<!\d)\d{6}(?!\d)/

      # An email address.
      EMAIL_PATTERN = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i

      # An http(s) URL up to the first whitespace/quote/angle bracket.
      URL_PATTERN = %r{https?://[^\s"'<>]+}i

      # A "key = value" / "key: value" / "key => value" assignment where the key
      # names a credential. Capture group 1 is the key+operator (preserved),
      # group 2 is the secret value (to be replaced by the caller).
      SENSITIVE_ASSIGNMENT = /
        (["']?(?:api[_-]?key|apikey|authorization|password|passwd|secret|token|otp|code)["']?\s*(?:=>|:|=)\s*)
        ("[^"]*"|'[^']*'|[^,\s}\]]+)
      /ix

      # Builds the same key/value assignment pattern as SENSITIVE_ASSIGNMENT but
      # for an arbitrary (non-credential) field name — used to scrub
      # report-payload fields. Capture group 1 is the key+operator (preserved).
      def payload_field_pattern(field)
        /(["']?#{Regexp.escape(field)}["']?\s*(?:=>|:|=)\s*)("[^"]*"|'[^']*'|[^,}\]]+)/i
      end

      # Last-4-preserving phone mask used in operational logs.
      def mask_phone(value)
        digits = value.to_s.gsub(/\D/, "")
        return "[phone]" if digits.blank?

        "[phone:***#{digits.last(4)}]"
      end

      # Reduces a URL to host + path, dropping the query string (which may carry
      # signatures/tokens) and the fragment. Used in operational logs.
      def redact_url_query(value)
        uri = URI.parse(value.to_s)
        uri.query = "[REDACTED]" if uri.query.present?
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        value.to_s.split("?").first.to_s
      end
    end
  end
end

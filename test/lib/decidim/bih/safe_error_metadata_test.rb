# frozen_string_literal: true

require "test_helper"
require "decidim/bih/safe_error_metadata"

module Decidim
  module Bih
    class SafeErrorMetadataTest < Minitest::Test
      ErrorWithCode = Struct.new(:message, :code) do
        def class
          StandardError
        end
      end

      def test_sanitizes_contact_urls_credentials_and_forwarding_payload_fields
        text = <<~TEXT
          SMTP failed for reporter@example.org +387 65 123 456
          address: "Vidovdanska 3", description: "Rupa ispred kuce",
          photo_url: "https://storage.example/photo?signature=secret",
          authorization: "Bearer abc", see https://errors.example/status?token=secret
        TEXT

        sanitized = SafeErrorMetadata.sanitize_text(text)

        assert_includes sanitized, "[email]"
        assert_includes sanitized, "[phone]"
        assert_includes sanitized, "[url]"
        assert_includes sanitized, "address: [redacted]"
        assert_includes sanitized, "description: [redacted]"
        assert_includes sanitized, "authorization: [redacted]"
        refute_match(/reporter@example\.org/, sanitized)
        refute_match(/65 123 456/, sanitized)
        refute_match(/Vidovdanska 3/, sanitized)
        refute_match(/Rupa ispred kuce/, sanitized)
        refute_match(/signature=secret/, sanitized)
        refute_match(/Bearer abc/, sanitized)
      end

      def test_extracts_sanitized_error_code
        error = ErrorWithCode.new("Timeout", "smtp_421")

        assert_equal "smtp_421", SafeErrorMetadata.error_code(error)
      end
    end
  end
end

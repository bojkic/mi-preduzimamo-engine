# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/infobip/error"

module Decidim
  module Bih
    module Infobip
      class ErrorTest < Minitest::Test
        def test_preserves_only_bounded_machine_readable_diagnostics
          error = Error.new(
            "unsafe provider response",
            http_status: "429",
            error_code: "RATE_LIMITED",
            error_group: "REJECTED"
          )

          assert_equal 429, error.http_status
          assert_equal "RATE_LIMITED", error.error_code
          assert_equal "REJECTED", error.error_group
          assert_equal(
            { http_status: 429, error_code: "RATE_LIMITED", error_group: "REJECTED" },
            error.metadata
          )
        end

        def test_rejects_out_of_range_or_free_text_diagnostics
          error = Error.new(
            "unsafe provider response",
            http_status: 999,
            error_code: "userId=private-recipient",
            error_group: "Private provider description"
          )

          assert_nil error.http_status
          assert_nil error.error_code
          assert_nil error.error_group
          assert_empty error.metadata
        end

        def test_scrubbed_exception_reconstruction_keeps_safe_metadata_only
          original = Error.new(
            "HTTP body echoed private-recipient",
            http_status: 503,
            error_code: "TEMPORARY_FAILURE",
            error_group: "UNDELIVERABLE"
          )

          rebuilt = original.exception("Infobip whatsapp chat delivery failed")

          refute_same original, rebuilt
          assert_equal "Infobip whatsapp chat delivery failed", rebuilt.message
          assert_equal original.metadata, rebuilt.metadata
          refute_includes rebuilt.message, "private-recipient"
        end
      end
    end
  end
end

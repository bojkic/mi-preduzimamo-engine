# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/access"
require_relative "../../../../app/services/decidim/bih/log_redactor"

module Decidim
  module Bih
    # What a log line may and may not carry. The primitives are shared with
    # SafeErrorMetadata through Decidim::Bih::Redaction; what is asserted here
    # is that LogRedactor actually APPLIES them — an owned pattern that no
    # caller applies protects nothing.
    class LogRedactorTest < Minitest::Test
      # A fabricated PostgreSQL unique-violation message, in the shape the
      # driver really produces: the colliding values live in DETAIL.
      UNIQUE_VIOLATION = <<~MESSAGE
        PG::UniqueViolation: ERROR:  duplicate key value violates unique constraint "index_decidim_users_on_email_and_decidim_organization_id"
        DETAIL:  Key (email, decidim_organization_id)=(mila@example.org, 1) already exists.
        CONTEXT:  phone +38765123456
      MESSAGE

      def test_sanitize_redacts_an_email_address
        sanitized = LogRedactor.sanitize("failed for mila.gradjanka+test@example.org while sending")

        refute_includes sanitized, "mila.gradjanka+test@example.org"
        assert_includes sanitized, "[email]"
        assert_includes sanitized, "while sending", "the operational shape survives"
      end

      def test_sanitize_still_masks_phones_urls_and_secrets
        sanitized = LogRedactor.sanitize(
          "POST https://api.example.org/send?token=abc to +38765123456 password=hunter2"
        )

        refute_includes sanitized, "+38765123456"
        assert_includes sanitized, "[phone:***3456]"
        assert_includes sanitized, "[REDACTED]"
        refute_includes sanitized, "hunter2"
        refute_includes sanitized, "token=abc"
      end

      # The message of a uniqueness violation is the one thing that must never
      # be logged, redacted or not: it names the colliding values.
      def test_constraint_violation_reports_the_class_and_the_index_only
        error = FakeError.new("ActiveRecord::RecordNotUnique", UNIQUE_VIOLATION)

        line = LogRedactor.constraint_violation(error)

        assert_includes line, "ActiveRecord::RecordNotUnique"
        assert_includes line, "index_decidim_users_on_email_and_decidim_organization_id"
        refute_includes line, "mila@example.org"
        refute_includes line, "+38765123456"
        refute_includes line, "DETAIL"
      end

      def test_constraint_violation_falls_back_to_the_class_alone
        error = FakeError.new("ActiveRecord::RecordNotUnique", "duplicate key value for mila@example.org")

        line = LogRedactor.constraint_violation(error)

        assert_equal "ActiveRecord::RecordNotUnique", line
        refute_includes line, "mila@example.org"
      end

      def test_constraint_violation_reads_a_named_constraint_too
        error = FakeError.new(
          "ActiveRecord::RecordNotUnique",
          %(PG::UniqueViolation: ERROR: duplicate key value violates unique constraint "decidim_users_nickname_key")
        )

        assert_equal "ActiveRecord::RecordNotUnique on decidim_users_nickname_key",
                     LogRedactor.constraint_violation(error)
      end

      # Stands in for an ActiveRecord error: this suite has no Rails.
      class FakeError
        attr_reader :message

        def initialize(class_name, message)
          @class_name = class_name
          @message = message
        end

        def class = @class_name
      end
    end
  end
end

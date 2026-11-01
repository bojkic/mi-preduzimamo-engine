# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require_relative "../../../../../lib/decidim/bih/safe_error_metadata"
require_relative "../../../../../app/services/decidim/bih/admin/private_action_reason"

module Decidim
  module Bih
    module Admin
      class PrivateActionReasonTest < Minitest::Test
        def test_requires_a_non_blank_reason
          refute PrivateActionReason.new(nil).valid?
          refute PrivateActionReason.new("  \n ").valid?
        end

        def test_rejects_a_reason_over_the_bound_instead_of_silently_truncating_it
          reason = PrivateActionReason.new("a" * (PrivateActionReason::MAX_LENGTH + 1))

          refute reason.valid?
          assert_empty reason.metadata
        end

        def test_collapses_whitespace_and_returns_explicit_private_metadata
          reason = PrivateActionReason.new("  Duplicate   pickup request \n confirmed  ")

          assert reason.valid?
          assert_equal "Duplicate pickup request confirmed", reason.value
          assert_equal({ private_reason: "Duplicate pickup request confirmed" }, reason.metadata)
        end

        def test_redacts_contact_and_credential_like_values_before_audit_storage
          reason = PrivateActionReason.new("Citizen person@example.test supplied token=secret")

          assert reason.valid?
          assert_equal "Citizen [email] supplied token=[redacted]", reason.value
        end
      end
    end
  end
end

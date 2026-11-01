# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"

# These models normally inherit from Decidim::ApplicationRecord. The policy
# methods asserted here are pure Ruby; the query scopes and persistence paths
# are exercised by host/generated-host Rails tests.
module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      def self.table_name=(*); end

      def self.belongs_to(*); end

      def self.has_many(*); end

      def self.has_one(*); end

      def self.validates(*); end

      def self.validate(*); end

      def self.before_validation(*); end

      def self.after_commit(*); end

      def self.scope(*); end
    end
    OPERATOR_POLICY_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../app/models/decidim/bih/operator_role"
require_relative "../../../../app/models/decidim/bih/operator_audit_event"
require_relative "../../../../app/models/decidim/bih/governance_approval"
require_relative "../../../../app/models/decidim/bih/governance_approval_attestation"
require_relative "../../../../app/models/decidim/bih/partner_profile"
require_relative "../../../../app/services/decidim/bih/operator_authorization"

module Decidim
  if const_defined?(:OPERATOR_POLICY_TEST_DEFINED_APPLICATION_RECORD, false)
    remove_const(:ApplicationRecord)
    remove_const(:OPERATOR_POLICY_TEST_DEFINED_APPLICATION_RECORD)
  end

  module Bih
    class OperatorAndPartnerPolicyTest < Minitest::Test
      Organization = Struct.new(:id, keyword_init: true)

      User = Struct.new(:admin, :organization, keyword_init: true) do
        def admin?
          admin
        end
      end

      def test_operator_roles_are_multi_select_capability_sets
        assert_includes OperatorRole::ROLES, "komsiluk_moderator"
        assert_includes OperatorRole::ROLES, "broadcast_operator"
        assert_includes OperatorRole::ROLES, "volunteer_reviewer"
        assert_includes OperatorRole::ROLES, "report_triager"
        assert_includes OperatorRole::ROLES, "release_approver"
        refute_includes OperatorRole::GRANTABLE_ROLES, "release_approver"
        assert_includes OperatorRole::ROLES, "debate_facilitator"
        refute_includes OperatorRole::GRANTABLE_ROLES, "debate_facilitator"

        assert_equal %w(report_triager), OperatorRole.roles_for_permission("reports_update_status")
        assert_equal %w(broadcast_operator), OperatorRole.roles_for_permission("broadcast_send_viber")
        assert_empty OperatorRole.roles_for_permission("broadcast_send_citywide")
        assert_empty OperatorRole.roles_for_permission("debate_facilitate")
        assert_equal %w(volunteer_reviewer), OperatorRole.roles_for_permission("volunteering_hours_review")
        assert_equal %w(support_agent), OperatorRole.roles_for_permission("operator_message_send")
        assert_equal %w(general_support_agent), OperatorRole.roles_for_permission("general_support_message_send")
        assert_empty OperatorRole.roles_for_permission("release_approval_attest")
        assert_empty OperatorRole.roles_for_permission("mi_bot_examples_read")
        assert_includes OperatorRole::ADMIN_ONLY_PERMISSIONS, "mi_bot_examples_read"
      end

      def test_support_role_requires_a_case_read_companion_role
        refute OperatorRole.grantable_role_set?(%w(support_agent))
        assert OperatorRole.grantable_role_set?(%w(support_agent report_triager))
        assert OperatorRole.grantable_role_set?(%w(support_agent), existing_roles: %w(volunteer_reviewer))
        assert OperatorRole.grantable_role_set?(%w(support_agent rewards_operator))
      end

      def test_retired_or_unknown_roles_are_not_grantable
        refute OperatorRole.grantable_role_set?(%w(debate_facilitator))
        refute OperatorRole.grantable_role_set?(%w(report_triager unknown_role))
      end

      def test_admin_only_permissions_are_not_granted_by_operator_roles
        operator_permissions = OperatorRole::ROLE_PERMISSIONS.values.flatten

        OperatorRole::ADMIN_ONLY_PERMISSIONS.each do |permission|
          refute_includes operator_permissions, permission
        end
      end

      def test_admin_in_current_organization_is_allowed_without_operator_role_lookup
        organization = Organization.new(id: 1)
        user = User.new(admin: true, organization:)

        assert_equal true, OperatorAuthorization.allowed?(user, "operator_roles_manage", organization:)
        assert_includes OperatorAuthorization.permissions_for(user, organization:), "operator_roles_manage"
      end

      def test_admin_from_another_organization_is_not_allowed_for_action_checks
        organization = Organization.new(id: 1)
        other_organization = Organization.new(id: 2)
        user = User.new(admin: true, organization: other_organization)

        assert_equal false, OperatorAuthorization.allowed?(user, "reports_read", organization:)
        assert_empty OperatorAuthorization.permissions_for(user, organization:)
        assert_nil OperatorAuthorization.role_for(user, :operations_read, organization:)
        refute OperatorAuthorization.operator?(user, organization:)
      end

      def test_inactive_admin_has_no_permissions_or_role
        organization = Organization.new(id: 1)
        [:blocked?, :deleted?].each do |state|
          user = User.new(admin: true, organization:)
          user.define_singleton_method(state) { true }

          refute OperatorAuthorization.allowed?(user, :operations_read, organization:)
          assert_empty OperatorAuthorization.permissions_for(user, organization:)
          assert_nil OperatorAuthorization.role_for(user, :operations_read, organization:)
          refute OperatorAuthorization.operator?(user, organization:)
        end
      end

      def test_operator_audit_metadata_removes_nested_pii_keys
        event = OperatorAuditEvent.allocate

        sanitized = event.send(
          :sanitized_hash,
          {
            "status" => "approved",
            "email" => "person@example.test",
            "nested" => {
              "note" => "private note",
              "count" => 3
            },
            "items" => [
              { "phone" => "+387", "visible" => true }
            ]
          }
        )

        assert_equal(
          {
            "status" => "approved",
            "nested" => { "count" => 3 },
            "items" => [{ "visible" => true }]
          },
          sanitized
        )
      end

      def test_governance_approval_metadata_keeps_only_allowed_bounded_keys
        sanitized = GovernanceApproval.sanitize_metadata(
          {
            "runbook" => "docs/operations/release-approval-policy.md",
            "recorded_from" => "admin_governance",
            "command_output" => "bundle exec TOKEN=secret",
            "nested" => {
              "token" => "private",
              "runbook" => "ignored because nested keys are not allowed here"
            },
            "dry_run_total" => 3
          }
        )

        assert_equal(
          {
            "runbook" => "docs/operations/release-approval-policy.md",
            "recorded_from" => "admin_governance",
            "dry_run_total" => 3
          },
          sanitized
        )
      end

      def test_governance_approval_digest_is_derived_from_summary_when_needed
        digest = GovernanceApproval.safe_evidence_digest(" release gate passed ")

        assert_match(/\Asha256:[0-9a-f]{64}\z/, digest)
        assert_equal digest, GovernanceApproval.safe_evidence_digest("release gate passed")
      end

      def test_governance_approval_uses_kind_specific_validity
        now = Time.current
        approval = GovernanceApproval.allocate
        approval.define_singleton_method(:governance_kind) { "privacy_retention" }
        approval.define_singleton_method(:approved_at) { now - 6.days }
        approval.define_singleton_method(:status) { "approved" }

        assert approval.current_approval?(at: now)
        assert_equal now + 1.day, approval.valid_until

        approval.define_singleton_method(:governance_kind) { "viber_launch" }
        assert_equal now + 84.days, approval.valid_until

        approval.define_singleton_method(:governance_kind) { "external_chat_launch" }
        assert_equal now + 84.days, approval.valid_until
        assert_equal "external_chat:instagram,whatsapp",
                     GovernanceApproval.external_chat_scope_key(%w(whatsapp instagram whatsapp unsupported))
      end

      def test_partner_profile_kind_policies_match_product_decisions
        assert_equal %w(association foundation informal_group), PartnerProfile::GOODWILL_ELIGIBLE_KINDS
        assert_equal %w(institution public_body), PartnerProfile::NOTICE_DIRECT_PUBLISH_KINDS
        assert_equal %w(
          association foundation institution public_body business local_community_body informal_group
        ), PartnerProfile::VOLUNTEER_OPPORTUNITY_KINDS

        association = profile(kind: "association", status: "verified")
        institution = profile(kind: "institution", status: "verified")
        informal_group = profile(kind: "informal_group", status: "verified")
        other = profile(kind: "other", status: "verified")
        unverified_group = profile(kind: "informal_group", status: "submitted")

        assert_equal true, association.goodwill_eligible?
        assert_equal false, institution.goodwill_eligible?
        assert_equal false, unverified_group.goodwill_eligible?
        assert_equal true, institution.official_publisher?
        assert_equal false, association.official_publisher?
        assert_equal true, association.volunteer_opportunity_eligible?
        assert_equal true, institution.volunteer_opportunity_eligible?
        assert_equal true, informal_group.volunteer_opportunity_eligible?
        assert_equal false, other.volunteer_opportunity_eligible?
        assert_equal false, unverified_group.can_publish_notices?
        assert_equal false, unverified_group.volunteer_opportunity_eligible?
      end

      private

      def profile(kind:, status:)
        PartnerProfile.allocate.tap do |partner_profile|
          partner_profile.define_singleton_method(:kind) { kind }
          partner_profile.define_singleton_method(:verification_status) { status }
          partner_profile.define_singleton_method(:legacy_user_group) { nil }
        end
      end
    end
  end
end

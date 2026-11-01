# frozen_string_literal: true

module Decidim
  module Bih
    # Historical independent LFBN owner/delegate confirmation for one release.
    #
    # The primary admin can nominate an eligible release approver, but cannot
    # create this row for them. The nominated person must sign in and attest
    # while the exact restart window is open. New releases no longer require or
    # expose this workflow. Existing rows stay append-only and their
    # linked operator audit event contains identifiers/status only.
    class GovernanceApprovalAttestation < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_governance_approval_attestations"

      APPROVAL_ROLE = "lfbn_platform_owner_or_delegate"

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :governance_approval,
                 class_name: "Decidim::Bih::GovernanceApproval",
                 inverse_of: :secondary_attestation

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id"

      belongs_to :operator_audit_event,
                 class_name: "Decidim::Bih::OperatorAuditEvent",
                 optional: true

      before_validation :set_defaults

      validates :approval_role, inclusion: { in: [APPROVAL_ROLE] }
      validates :attested_at, presence: true
      validates :governance_approval_id, uniqueness: true
      validate :matches_exact_release_nomination
      validate :inside_restart_window
      validate :release_approver_role_is_active

      def readonly?
        persisted? && operator_audit_event_id_in_database.present?
      end

      def self.storage_available?
        connection.data_source_exists?(table_name)
      rescue ActiveRecord::ActiveRecordError
        false
      end

      private

      def set_defaults
        self.approval_role ||= APPROVAL_ROLE
        self.attested_at ||= Time.current
        self.organization ||= governance_approval&.organization
      end

      def matches_exact_release_nomination
        return if governance_approval.blank? || user.blank?

        errors.add(:governance_approval, :invalid) unless governance_approval.governance_kind == "release_restart"
        errors.add(:organization, :invalid) unless governance_approval.organization == organization
        errors.add(:user, :invalid) unless governance_approval.secondary_approver == user
        errors.add(:user, :taken) if governance_approval.user == user
      end

      def inside_restart_window
        return if governance_approval.blank? || attested_at.blank?

        starts_at = governance_approval.restart_window_starts_at
        ends_at = governance_approval.restart_window_ends_at
        return if starts_at.present? && ends_at.present? && attested_at.between?(starts_at, ends_at)

        errors.add(:attested_at, :invalid)
      end

      def release_approver_role_is_active
        return if user.blank? || organization.blank?
        return if Decidim::Bih::OperatorRole
                  .active_for(user, organization)
                  .for_permission("release_approval_attest")
                  .exists?

        errors.add(:user, :invalid)
      end
    end
  end
end

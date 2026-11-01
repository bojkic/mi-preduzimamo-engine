# frozen_string_literal: true

module Decidim
  module Bih
    module Governance
      # Persists a separately authenticated release attestation and audit event.
      class AttestationRecorder
        def self.call(**attributes)
          new(**attributes).call
        end

        def initialize(approval:, actor:, role:)
          @approval = approval
          @actor = actor
          @role = role
        end

        def call
          attestation = Decidim::Bih::GovernanceApprovalAttestation.new(
            organization: approval.organization,
            governance_approval: approval,
            user: actor,
            approval_role: Decidim::Bih::GovernanceApprovalAttestation::APPROVAL_ROLE,
            attested_at: Time.current
          )

          ActiveRecord::Base.transaction do
            attestation.save!
            audit_event = Decidim::Bih::OperatorAuditEvent.record!(
              organization: approval.organization,
              actor:,
              event_type: "release_approval_independently_attested",
              permission: "release_approval_attest",
              role:,
              resource: attestation,
              metadata: {
                "governance_approval_id" => approval.id,
                "scope_key" => approval.scope_key,
                "app_sha" => approval.app_sha,
                "engine_sha" => approval.engine_sha
              }
            )
            attestation.update!(operator_audit_event: audit_event)
          end

          attestation
        end

        private

        attr_reader :approval, :actor, :role
      end
    end
  end
end

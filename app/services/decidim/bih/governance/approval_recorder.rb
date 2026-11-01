# frozen_string_literal: true

module Decidim
  module Bih
    module Governance
      # Records a governance approval and its operator audit row together.
      class ApprovalRecorder
        def self.call(**attributes)
          new(**attributes).call
        end

        def initialize(organization:, actor:, role:, attributes:, runbook:)
          @organization = organization
          @actor = actor
          @role = role
          @attributes = attributes.to_h
          @runbook = runbook
        end

        def call
          approval = build_approval

          ActiveRecord::Base.transaction do
            approval.save!
            audit_event = Decidim::Bih::OperatorAuditEvent.record!(
              organization:,
              actor:,
              event_type: "governance_approval_recorded",
              permission: "operations_read",
              role:,
              resource: approval,
              metadata: audit_metadata_for(approval)
            )
            approval.update!(operator_audit_event: audit_event)
          end

          approval
        end

        private

        attr_reader :organization, :actor, :role, :attributes, :runbook

        def build_approval
          Decidim::Bih::GovernanceApproval.new(
            organization:,
            user: actor,
            governance_kind: attributes.fetch("governance_kind"),
            approval_role: release_restart? ? Decidim::Bih::GovernanceApproval::RELEASE_APPROVAL_ROLE : role,
            status: attributes.fetch("status"),
            scope_key: attributes["scope_key"],
            app_sha: attributes["app_sha"],
            engine_sha: attributes["engine_sha"],
            restart_window_starts_at: attributes["restart_window_starts_at"],
            restart_window_ends_at: attributes["restart_window_ends_at"],
            backup_health_status: attributes["backup_health_status"],
            restore_smoke_status: attributes["restore_smoke_status"],
            backup_manifest_digest: attributes["backup_manifest_digest"],
            migration_state: attributes["migration_state"],
            evidence_summary: attributes["evidence_summary"],
            evidence_digest: attributes["evidence_digest"],
            metadata: {
              "recorded_from" => "admin_governance",
              "runbook" => runbook,
              "dry_run_status" => attributes["dry_run_status"],
              "dry_run_total" => attributes["dry_run_total"]
            }.compact.merge(local_verification_metadata)
          )
        end

        def local_verification_metadata
          return {} unless release_restart?

          model = Decidim::Bih::GovernanceApproval
          lane = attributes["verification_lane"].to_s
          scopes = model.local_verification_policy.dig("verification", "lanes", lane, "required_scopes")
          {
            "verification_lane" => lane,
            "local_gate_status" => attributes["local_gate_status"],
            "verification_result_digest" => attributes["verification_result_digest"],
            "verification_policy_sha256" => model.local_verification_policy_sha256,
            "required_scopes" => (Array(scopes) + Array(attributes["required_scopes"])).uniq.sort
          }
        rescue KeyError, TypeError, NoMethodError, Errno::ENOENT, Psych::Exception
          # Missing policy cannot turn into a legacy approval; validation fails closed.
          { "verification_lane" => lane }
        end

        def audit_metadata_for(approval)
          {
            "governance_kind" => approval.governance_kind,
            "governance_approval_id" => approval.id,
            "status" => approval.status,
            "scope_key" => approval.scope_key,
            "evidence_digest" => approval.evidence_digest,
            "app_sha" => approval.app_sha,
            "engine_sha" => approval.engine_sha
          }
        end

        def release_restart?
          attributes["governance_kind"] == "release_restart"
        end
      end
    end
  end
end

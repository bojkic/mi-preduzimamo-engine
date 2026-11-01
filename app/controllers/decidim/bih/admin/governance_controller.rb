# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Owner-approval and operational-governance handoffs.
      class GovernanceController < Decidim::Bih::Admin::ApplicationController
        RUNBOOKS = {
          "viber_launch" => "docs/operations/viber-webhook-live-verification.md",
          "external_chat_launch" => "docs/operations/omnichannel-chat-live-verification.md",
          "release_restart" => "docs/operations/release-approval-policy.md",
          "backup_restore" => "docs/operations/backup-and-restore.md",
          "cron_maintenance" => "docs/operations/crontab.md",
          "privacy_retention" => "docs/operations/privacy-retention-sweeps.md"
        }.freeze

        before_action -> { require_bih_permission!(:operations_read) }
        before_action :ensure_global_admin!, only: :create
        before_action :ensure_known_governance_kind!, only: :create
        before_action :ensure_governance_storage_available!, only: :create

        def index
          @governance_rows = governance_rows
        end

        def create
          approval = Decidim::Bih::Governance::ApprovalRecorder.call(
            organization: current_organization,
            actor: current_user,
            role: current_bih_role_for(:operations_read),
            attributes: approval_attributes,
            runbook: RUNBOOKS.fetch(governance_kind)
          )

          flash[:notice] = t("decidim.bih.admin.governance.create.success")
          redirect_to "#{governance_path}#governance-#{approval.governance_kind}"
        rescue ActiveRecord::RecordInvalid => e
          @failed_governance_kind = governance_kind
          @failed_approval = e.record
          @governance_rows = governance_rows
          flash.now[:alert] = t("decidim.bih.admin.governance.create.error")
          render :index, status: :unprocessable_entity
        rescue ActiveRecord::StatementInvalid => e
          log_governance_storage_unavailable(e)
          redirect_to governance_path, alert: t("decidim.bih.admin.governance.storage_unavailable")
        end

        private

        def governance_kind
          params[:governance_kind].to_s
        end

        def ensure_governance_storage_available!
          return if Decidim::Bih::GovernanceApproval.storage_available?

          log_governance_storage_unavailable
          redirect_to governance_path, alert: t("decidim.bih.admin.governance.storage_unavailable")
        end

        def ensure_known_governance_kind!
          raise ActionController::RoutingError, "Unknown governance workflow" unless RUNBOOKS.has_key?(governance_kind)
        end

        def approval_attributes
          attributes = params
                       .require(:governance_approval)
                       .permit(
                         :status, :scope_key, :app_sha, :engine_sha, :evidence_summary, :evidence_digest,
                         :restart_window_starts_at, :restart_window_ends_at,
                         :verification_lane, :local_gate_status, :verification_result_digest,
                         :backup_health_status, :restore_smoke_status,
                         :backup_manifest_digest, :migration_state, required_scopes: []
                       )
                       .to_h
                       .merge("governance_kind" => governance_kind)
          if governance_kind == "release_restart"
            attributes["scope_key"] = Decidim::Bih::GovernanceApproval.release_scope_key(
              attributes["app_sha"],
              attributes["engine_sha"]
            )
            return attributes
          end
          return attributes unless governance_kind == "privacy_retention"

          summary = Decidim::Bih::Admin::RetentionSummary.new(organization: current_organization).summary
          attributes.merge(
            "scope_key" => attributes["scope_key"].presence || summary.fetch(:scope_key),
            "dry_run_status" => summary[:status],
            "dry_run_total" => summary[:total]
          )
        end

        def governance_rows
          @governance_storage_available = Decidim::Bih::GovernanceApproval.storage_available?
          latest_by_kind = Decidim::Bih::GovernanceApproval.latest_by_kind(current_organization)

          build_governance_rows(latest_by_kind)
        rescue ActiveRecord::StatementInvalid => e
          @governance_storage_available = false
          log_governance_storage_unavailable(e)
          build_governance_rows({})
        end

        def build_governance_rows(latest_by_kind)
          %w(
            viber_launch
            external_chat_launch
            release_restart
            backup_restore
            cron_maintenance
            privacy_retention
          ).map do |key|
            {
              id: key,
              title: t("decidim.bih.admin.governance.rows.#{key}.title"),
              body: t("decidim.bih.admin.governance.rows.#{key}.body"),
              status: t("decidim.bih.admin.governance.rows.#{key}.status"),
              runbook: RUNBOOKS.fetch(key),
              evidence: t("decidim.bih.admin.governance.rows.#{key}.evidence"),
              latest_approval: latest_by_kind[key]
            }
          end
        end

        def log_governance_storage_unavailable(exception = nil)
          detail = exception ? " (#{exception.class})" : ""
          Rails.logger.warn("[Admin::Governance] approval storage unavailable#{detail}; check pending migrations")
        end
      end
    end
  end
end

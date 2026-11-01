# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Staff close an open staff task they have handled outside a decision
      # (e.g. a police contact made by phone). The task is kept as history.
      class ReportTasksController < ApplicationController
        REASONS = %w(done not_needed handled_elsewhere).freeze

        before_action -> { require_bih_permission!(:reports_read) }
        before_action -> { require_bih_permission!(:reports_update_status) }

        def close
          report = Report.find_by!(organization: current_organization, reference: params[:reference])
          task = report.obligations.open.find_by!(id: params[:id], actor: "staff")
          reason = REASONS.include?(params[:reason]) ? params[:reason] : "done" # the page sends no reason: "resolved"
          event = report.record_event!("case_task_closed", actor: current_user, metadata: { obligation_id: task.id, kind: task.kind, reason: })
          ReportObligations.supersede!(task, by: event)
          task.update!(metadata: task.metadata.merge("closed_reason" => reason, "closed_by_id" => current_user.id))
          OperatorAuditEvent.record!(organization: current_organization, actor: current_user, event_type: "case_task_closed", resource: report,
                                     permission: "reports_update_status", metadata: { obligation_id: task.id, kind: task.kind, reason: })
          redirect_to admin_bih_report_path(reference: report.reference), notice: t("decidim.bih.report_tasks.closed")
        end
      end
    end
  end
end

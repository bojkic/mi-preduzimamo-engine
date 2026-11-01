# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class ReportReviewProposalsController < ApplicationController
        before_action -> { require_bih_permission!(:reports_read) }
        before_action -> { require_bih_permission!(:reports_update_status) }
        before_action :load_report
        rescue_from ReportDecision::Invalid, with: :invalid_proposal

        def create
          raise ReportDecision::Invalid, t("decidim.bih.review_workspace.ai.disabled") unless ReportReviewAssistant.active?(current_organization)

          @report.record_event!("review_proposal_requested", actor: current_user, metadata: {})
          audit_operator_action!("review_proposal_requested", permission: :reports_update_status, resource: @report)
          ReportReviewProposalJob.perform_later(@report.id, retry_failed: true)
          redirect_to case_path, notice: t("decidim.bih.review_workspace.ai.queued")
        end

        def adopt
          proposal = @report.review_proposals.find(params[:id])
          raise ReportDecision::Invalid, t("decidim.bih.case_agent.nothing_to_accept") if proposal.suggested_values["draft_action"].blank?
          raise ReportDecision::Invalid, t("decidim.bih.review_workspace.ai.confirm_replace") if @report.review_draft.present? && params[:replace_draft] != "1"
          raise ReportDecision::Invalid, t("decidim.bih.review_workspace.errors.stale") unless proposal.current?

          ReportDecision.new(@report, current_user).call(action: "save_draft", values: proposal.suggested_values, version: params[:input_version])
          redirect_to "#{case_path}#report-decision-form", notice: t("decidim.bih.review_workspace.ai.adopted")
        end

        private

        def load_report
          @report = Report.find_by!(organization: current_organization, reference: params[:reference])
          response.cache_control.replace(no_store: true, private: true)
          response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
        end

        def case_path
          context = ReportQueueContext.from_path(params[:return_to], organization: current_organization, actor: current_user)
          admin_bih_report_path(reference: @report.reference, return_to: context.path)
        end

        def invalid_proposal(error)
          redirect_to case_path, alert: error.message
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class ReportReviewBatchesController < ApplicationController
        before_action -> { require_bih_permission!(:reports_read) }
        before_action -> { require_bih_permission!(:reports_update_status) }
        before_action :load_context
        rescue_from ReportDecision::Invalid, with: :invalid_batch

        def index
          scope = @queue_context.scope
          @page_count = [(scope.count.to_f / ReportReviewBatch::MAX_ITEMS).ceil, 1].max
          @page = @queue_context.params["page"].to_i.clamp(1, @page_count)
          reports = scope.offset((@page - 1) * ReportReviewBatch::MAX_ITEMS).limit(ReportReviewBatch::MAX_ITEMS)
          @rows = reports.map { |report| draft_row(report) }
        end

        def preview
          selected = items.select { |item| item["choose"] == "1" }
          raise ReportDecision::Invalid, t("decidim.bih.review_workspace.batch.select_one") if selected.empty?

          @results = batch.prepare(selected)
        end

        def confirm
          @results = batch.apply(items)
          render :results
        end

        private

        def batch = ReportReviewBatch.new(organization: current_organization, actor: current_user)

        def items
          value = params[:batch_items]
          unless value.is_a?(ActionController::Parameters) && value.keys.size.between?(1, ReportReviewBatch::MAX_ITEMS)
            raise ReportDecision::Invalid, t("decidim.bih.review_workspace.errors.too_large")
          end

          value.values.map do |item|
            raise ReportDecision::Invalid, t("decidim.bih.review_workspace.errors.invalid_action") unless item.is_a?(ActionController::Parameters)

            item.permit(:reference, :action, :version, :choose, :token, :approve, values: ReportDecision::FIELDS).to_h
          end
        end

        def draft_row(report)
          draft = report.review_draft
          proposal = ai_proposal_for(report, draft)
          values = if draft.present?
                     ReportReviewProposal.staff_draft_values(report)
                   elsif proposal&.current?
                     proposal.suggested_values
                   else
                     {}
                   end
          action = values["draft_action"]
          { report:, values:, action:, ready: batch_action_allowed?(report, action) && !stale_draft?(report, draft), origin: draft.present? ? "human" : "ai",
            proposal: draft.present? ? nil : proposal,
            version: ReportReviewVersion.digest(report) }
        rescue ArgumentError, KeyError, TypeError
          { report:, values: {}, ready: false, version: ReportReviewVersion.digest(report) }
        end

        def ai_proposal_for(report, draft)
          return if draft.present? || !ReportReviewAssistant.active?(current_organization)

          ReportReviewProposal.for_review(report)
        end

        def batch_action_allowed?(report, action)
          ReportReviewBatch::ACTIONS.include?(action) && ReportDecision.allowed_actions(report).include?(action) &&
            OperatorAuthorization.allowed?(current_user, ReportDecision::PERMISSIONS.fetch(action, :reports_update_status), organization: current_organization)
        end

        def stale_draft?(report, draft)
          draft.present? && report.last_citizen_reply_at && report.last_citizen_reply_at > Time.zone.parse(draft.fetch("saved_at"))
        end

        def load_context
          context = ReportQueueContext.from_path(params[:return_to], organization: current_organization, actor: current_user)
          @queue_context = ReportQueueContext.new(organization: current_organization, actor: current_user, params: context.params.merge("batch" => "1"))
          @list_path = ReportQueueContext.new(organization: current_organization, actor: current_user, params: context.params.except("batch")).path
          response.cache_control.replace(no_store: true, private: true)
          response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
          response.set_header("X-Robots-Tag", "noindex, nofollow")
        end

        def invalid_batch(error)
          redirect_to admin_bih_report_review_batch_path(return_to: @queue_context.path), alert: error.message
        end
      end
    end
  end
end

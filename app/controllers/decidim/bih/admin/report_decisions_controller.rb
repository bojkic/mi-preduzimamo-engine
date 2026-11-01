# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class ReportDecisionsController < ApplicationController
        before_action -> { require_bih_permission!(:reports_read) }
        before_action :load_case
        before_action :protect_private_response
        rescue_from ReportDecision::Invalid, ReportDispatching::Invalid, ReportPlanning::Invalid,
                    ReportCaseWorkflow::Invalid, ActiveRecord::RecordInvalid, with: :invalid_decision

        def create
          @action = params[:decision_action].to_s
          @values = params.fetch(:decision, ActionController::Parameters.new).permit(*ReportDecision::FIELDS).to_h
          if params[:intent] == "draft"
            @values["draft_action"] = @action
            @action = "save_draft"
          end
          @version = params[:input_version].to_s
          @next_case = queue_context.successor(@report) if params[:after_decision] == "next" && @action != "save_draft"
          @open_next = params[:after_decision] == "next" && @action != "save_draft"
          if ReportDecision::SEND_ACTIONS.include?(@action)
            @snapshot = decision.preview(action: @action, values: @values, version: @version)
            @preview_token = envelope.seal({ actor_id: current_user.id, report_id: @report.id, action: @action, values: @values,
                                             version: @version, mail_digest: @snapshot[:digest], expires_at: 10.minutes.from_now.to_i,
                                             return_to: safe_return_path, next_case: @next_case, open_next: @open_next },
                                           purpose: "report-decision", salt: "bih-report-decision-v1")
            render :preview
          else
            decision.call(action: @action, values: @values, version: @version, confirmed: params[:confirm_decision] == "1")
            redirect_to completion_path, notice: t("decidim.bih.review_workspace.#{@action == "save_draft" ? "draft_saved" : "saved"}")
          end
        end

        def confirm
          token = envelope.open(params[:preview_token], purpose: "report-decision", salt: "bih-report-decision-v1")
          unless token["actor_id"] == current_user.id && token["report_id"] == @report.id && token["expires_at"].to_i > Time.current.to_i && params[:confirm_decision] == "1"
            raise ReportDecision::Invalid, t("decidim.bih.review_workspace.errors.preview_required")
          end

          decision.call(action: token.fetch("action"), values: token.fetch("values"), version: token.fetch("version"),
                        confirmed: true, approved_mail_digest: token.fetch("mail_digest"))
          @open_next = token["open_next"]
          @next_case = token["next_case"]
          redirect_to completion_path(return_to: permitted_return(token["return_to"])),
                      notice: t("decidim.bih.review_workspace.send_queued")
        rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError, KeyError, TypeError, ArgumentError
          invalid_decision(ReportDecision::Invalid.new(t("decidim.bih.review_workspace.errors.preview_required")))
        end

        def candidates
          @matches = ReportDuplicateCandidates.new(@report).call(query: params[:q])
          render partial: "decidim/bih/admin/reports/duplicate_candidates", locals: { matches: @matches }
        end

        def reconcile
          require_bih_permission!(:reports_retry_forwarding)
          dispatch = @report.dispatches.find(params[:dispatch_id])
          unless params[:confirm_decision] == "1" && %w(accepted not_sent).include?(params[:outcome])
            raise ReportDecision::Invalid, t("decidim.bih.review_workspace.errors.confirmation")
          end

          ReportDispatching.reconcile!(dispatch:, actor: current_user, accepted: params[:outcome] == "accepted", evidence: params[:reconciliation_evidence])
          redirect_to case_path, notice: t("decidim.bih.review_workspace.saved")
        end

        private

        def decision = ReportDecision.new(@report, current_user)

        def envelope = Infobip::EncryptedJobEnvelope

        def safe_return_path = permitted_return(params[:return_to])

        def case_path = admin_bih_report_path(reference: @report.reference, return_to: safe_return_path)

        def queue_context
          @queue_context ||= ReportQueueContext.from_path(params[:return_to], organization: current_organization, actor: current_user)
        end

        def permitted_return(value)
          ReportQueueContext.from_path(value, organization: current_organization, actor: current_user).path
        end

        def completion_path(return_to: safe_return_path)
          return admin_bih_report_path(reference: @report.reference, return_to:) unless @open_next
          return return_to unless @next_case && Report.exists?(organization: current_organization, reference: @next_case["reference"])

          admin_bih_report_path(reference: @next_case["reference"], return_to: permitted_return(@next_case["return_to"]))
        end

        def load_case
          @report = Report.find_by!(organization: current_organization, reference: params[:reference])
        end

        def invalid_decision(error)
          redirect_to case_path, alert: error.message
        end

        def protect_private_response
          response.cache_control.replace(no_store: true, private: true)
          response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
          response.set_header("X-Robots-Tag", "noindex, nofollow")
        end
      end
    end
  end
end

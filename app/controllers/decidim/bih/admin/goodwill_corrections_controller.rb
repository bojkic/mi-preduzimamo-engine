# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class GoodwillCorrectionsController < ApplicationController
        before_action -> { require_bih_permission!(:goodwill_reverse_transaction) }

        def index
          @corrections = scope.includes(:account, :actor, :settlement).order(id: :desc).page(params[:page]).per(30)
        end

        def preview
          @report = reports.find_by!(reference: params[:reference].to_s.strip)
          @preview = Goodwill::SourceCreditCorrection.preview(report: @report)
          return render :preview unless @preview

          @token = verifier.generate({ "report_id" => @report.id, "organization_id" => current_organization.id,
                                       "actor_id" => current_user.id, "version" => @preview[:decision_version],
                                       "wallet_before" => @preview[:wallet_before], "previous_target" => @preview[:previous_target] },
                                     expires_in: 30.minutes, purpose: "apply")
        end

        def create
          data = verifier.verified(params[:preview_token].to_s, purpose: "apply")
          unless data && data["actor_id"] == current_user.id && data["organization_id"] == current_organization.id
            raise Goodwill::SourceCreditCorrection::StaleDecision
          end
          report = reports.find(data.fetch("report_id"))
          rationale = params[:reason].to_s.strip
          raise ArgumentError if rationale.blank? || rationale.length > 1_000

          original = Goodwill::Transaction.find_by!(organization: current_organization, idempotency_key: Goodwill::IdempotencyKey.report(report.id), kind: "earn")
          account = original.entries.where("amount > 0").first!.account
          Goodwill::AccountLocks.with(account) do
            report.lock!
            fresh = Goodwill::SourceCreditCorrection.preview(report:)
            unless fresh && fresh[:wallet_before] == data["wallet_before"] && fresh[:previous_target] == data["previous_target"]
              raise Goodwill::SourceCreditCorrection::StaleDecision
            end
            correction = Goodwill::SourceCreditCorrection.call(report:, actor: current_user, expected_version: data.fetch("version"), reason: rationale)
            audit_operator_action!("goodwill_source_correction_reviewed", permission: "goodwill_reverse_transaction",
                                   resource: report, metadata: { correction_id: correction&.id, reason: rationale })
          end
          flash[:notice] = t("decidim.bih.admin.goodwill_corrections.saved")
          redirect_to goodwill_corrections_path
        rescue Goodwill::SourceCreditCorrection::StaleDecision, ArgumentError, ActiveRecord::RecordNotFound
          flash[:alert] = t("decidim.bih.admin.goodwill_corrections.stale")
          redirect_to goodwill_corrections_path
        end

        def settle
          correction = scope.find(params[:id])
          Goodwill::AccountLocks.with(correction.account) do
            Goodwill::SourceCreditCorrection.settle!(correction, actor: current_user)
            audit_operator_action!("goodwill_source_recovery_reviewed", permission: "goodwill_reverse_transaction",
                                   resource: correction, metadata: { status: correction.settlement.reload.status })
          end
          flash[:notice] = t("decidim.bih.admin.goodwill_corrections.saved")
          redirect_to goodwill_corrections_path
        rescue Goodwill::SourceCreditCorrection::StaleDecision
          flash[:alert] = t("decidim.bih.admin.goodwill_corrections.stale")
          redirect_to goodwill_corrections_path
        end

        private

        def scope
          Goodwill::CreditCorrection.where(organization: current_organization)
        end

        def reports
          Decidim::Bih::Report.where(organization: current_organization)
        end

        def verifier
          Rails.application.message_verifier(:goodwill_source_correction)
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class ReportCollectionsController < ApplicationController
        before_action -> { require_bih_permission!(:reports_read) }
        before_action -> { require_bih_permission!(:reports_update_status) }, only: [:create, :update, :ready]
        before_action -> { require_bih_permission!(:reports_retry_forwarding) }, only: [:record_submission]
        before_action :load_collection, except: [:index, :create]
        before_action :protect_private_response
        rescue_from ReportPlanning::Invalid, ActiveRecord::RecordInvalid, with: :invalid

        def index
          @collections = ReportCollection.where(organization: current_organization).includes(:assigned_to).order(created_at: :desc)
        end

        def show; end

        def create
          @collection = ReportCollection.new(organization: current_organization)
          # Validate title/topic and staff owner before insertion; no empty drafts.
          values = collection_params.to_h.symbolize_keys
          @collection.assign_attributes(values.slice(:title, :topic, :summary))
          @collection.assigned_to = ReportCaseWorkflow.staff(current_organization).find_by(id: values[:assigned_to_id])
          @collection.review_due_at = values[:review_due_at]
          unless @collection.assigned_to && @collection.review_due_at && @collection.review_due_at > Time.current
            raise ReportPlanning::Invalid, t("decidim.bih.report_planning.errors.owner_due_required")
          end

          @collection.save!
          OperatorAuditEvent.record!(organization: current_organization, actor: current_user, event_type: "collection_created",
                                     permission: :reports_update_status, resource: @collection)
          redirect_to admin_bih_report_collection_path(@collection)
        end

        def update
          workflow.update(collection_params)
          redirect_to admin_bih_report_collection_path(@collection), notice: t("decidim.bih.report_planning.saved")
        end

        def ready
          workflow.ready
          redirect_to admin_bih_report_collection_path(@collection), notice: t("decidim.bih.report_planning.saved")
        end

        def export
          raise ReportPlanning::Invalid, t("decidim.bih.report_planning.errors.not_ready") unless %w(ready submitted closed).include?(@collection.state)
          if @collection.state == "ready" && (@collection.submission_snapshot != @collection.submission_text ||
              @collection.reports.any? { |r| !r.planned? || r.review_state != "validated" })
            raise ReportPlanning::Invalid, t("decidim.bih.report_planning.errors.not_ready")
          end

          send_data @collection.submission_snapshot, filename: "zbirna-prijava-#{@collection.id}.txt", type: "text/plain; charset=utf-8"
        end

        def record_submission
          workflow.record_submission(recipient: params[:recipient], reference: params[:external_reference], confirmed: params[:confirm_submission])
          redirect_to admin_bih_report_collection_path(@collection), notice: t("decidim.bih.report_planning.saved")
        end

        private

        def workflow = ReportCollectionWorkflow.new(@collection, current_user)

        def load_collection = @collection = ReportCollection.find_by!(id: params[:id], organization: current_organization)

        def collection_params = params.require(:collection).permit(:title, :topic, :summary, :assigned_to_id, :review_due_at)

        def invalid(error)
          redirect_to(@collection&.persisted? ? admin_bih_report_collection_path(@collection) : admin_bih_report_collections_path, alert: error.message)
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

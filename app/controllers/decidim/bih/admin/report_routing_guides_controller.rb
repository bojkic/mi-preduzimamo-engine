# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class ReportRoutingGuidesController < ApplicationController
        before_action -> { require_bih_permission!(:sistem48_settings_manage) }
        def index
          @guides = ReportRoutingGuide.where(organization: current_organization).order(:key)
          @guide = ReportRoutingGuide.new
        end

        def create
          @guide = ReportRoutingGuide.new(values.merge(organization: current_organization, approved_by: current_user))
          save_guide
        end

        def update
          @guide = ReportRoutingGuide.find_by!(organization: current_organization, id: params[:id])
          @guide.assign_attributes(values.merge(approved_by: current_user))
          save_guide
        end

        def destroy
          guide = ReportRoutingGuide.find_by!(organization: current_organization, id: params[:id])
          guide.update!(active: false, approved_by: current_user)
          audit_operator_action!("report_routing_guide_deactivated", permission: :sistem48_settings_manage, resource: guide)
          redirect_to admin_bih_report_routing_guides_path
        end

        def revoke_share
          share = ReportEvidenceShare.joins(evidence_item: :report).where(decidim_bih_reports: { decidim_organization_id: current_organization.id }).find(params[:id])
          share.revoke!
          audit_operator_action!("report_evidence_share_revoked", permission: :sistem48_settings_manage, resource: share)
          redirect_to admin_bih_report_routing_guides_path
        end

        private

        def values
          permitted = params.require(:guide).permit(:key, :title, :body_sr, :active, categories: [], approved_recipient_keys: []).to_h
          %w(categories approved_recipient_keys).each do |key|
            permitted[key] = Array(permitted[key]).reject(&:blank?) if permitted.has_key?(key)
          end
          permitted
        end

        def save_guide
          if @guide.save
            audit_operator_action!("report_routing_guide_reviewed", permission: :sistem48_settings_manage, resource: @guide, metadata: { version: @guide.version })
            redirect_to admin_bih_report_routing_guides_path
          else
            @guides = ReportRoutingGuide.where(organization: current_organization).order(:key)
            render :index, status: :unprocessable_entity
          end
        end
      end
    end
  end
end

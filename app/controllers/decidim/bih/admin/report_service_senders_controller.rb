# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class ReportServiceSendersController < ApplicationController
        before_action -> { require_bih_permission!(:reports_mailbox_manage) }
        def index
          @senders = ReportServiceSender.where(organization: current_organization).order(:label)
          response.cache_control.replace(no_store: true, private: true)
        end
        def create
          sender = ReportServiceSender.create!(organization: current_organization, email: params[:email].to_s.strip.downcase, label: params[:label].to_s.first(100))
          audit_operator_action!("service_sender_added", permission: :reports_mailbox_manage, resource: sender)
          redirect_to report_service_senders_path
        end
        def deactivate
          sender = ReportServiceSender.where(organization: current_organization).find(params[:id])
          sender.update!(active: false)
          audit_operator_action!("service_sender_deactivated", permission: :reports_mailbox_manage, resource: sender)
          redirect_to report_service_senders_path
        end
      end
    end
  end
end

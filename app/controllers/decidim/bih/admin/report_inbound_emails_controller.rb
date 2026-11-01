# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class ReportInboundEmailsController < ApplicationController
        before_action -> { require_bih_permission!(:reports_mailbox_manage) }
        before_action :private_response
        def index
          @emails = scope.where(state: %w(review failed)).order(internal_date: :desc).limit(100)
        end

        def show
          @email = scope.find(params[:id])
        end

        def history
          email = scope.find(params[:id])
          ReportMailbox::HistoryImport.mark!(email)
          audit_operator_action!("mail_imported_as_history", permission: :reports_mailbox_manage, resource: email)
          redirect_to report_inbound_email_path(email)
        rescue ReportMailbox::HistoryImport::AlreadyEffectful
          redirect_to report_inbound_email_path(email), alert: I18n.t("decidim.bih.report_mailbox.history_already_effectful")
        end

        def history_import
          upload = params[:history_file]
          raise ActionController::BadRequest unless upload.respond_to?(:tempfile) && upload.tempfile.size.between?(1, ReportMailbox::Ingest::MAX_BYTES)

          raw = upload.tempfile.read(ReportMailbox::Ingest::MAX_BYTES + 1)
          email = ReportMailbox::Ingest.new(organization: current_organization, adapter: nil).import_history!(raw:)
          audit_operator_action!("mail_imported_as_history", permission: :reports_mailbox_manage, resource: email)
          redirect_to report_inbound_email_path(email)
        end

        def link
          email = scope.find(params[:id])
          references = ReportMailbox::Reference.scan(params[:references])
          reports = Report.where(organization: current_organization, reference: references).order(:id).to_a
          raise ActiveRecord::RecordNotFound unless reports.size == references.size && reports.any?

          email.with_lock do
            reports.each do |report|
              link = email.inbound_email_links.find_or_initialize_by(report:)
              link.assign_attributes(matching_method: "manual", assurance: "association", created_by: current_user)
              link.save!
              report.record_event!("city_email_manually_linked", actor: current_user, metadata: { inbound_email_id: email.id, history_only: email.history_only })
              unless email.history_only
                ReportCityReply::StaffNotice.fulfil_review!(report:, inbound_email: email, by: current_user, kinds: ["mail_review"])
                ReportCityReply.record!(report:, inbound_email: email, link:)
              end
            end
            email.update!(state: email.history_only ? "history" : "processed")
            audit_operator_action!("mail_manually_linked", permission: :reports_mailbox_manage, resource: email, metadata: { report_ids: reports.map(&:id) })
          end
          redirect_to report_inbound_email_path(email)
        end

        def dismiss
          email = scope.find(params[:id])
          email.with_lock do
            email.update!(state: "ignored", dismissed_by: current_user)
            email.reports.order(:id).each do |report|
              ReportCityReply::StaffNotice.fulfil_review!(report:, inbound_email: email, by: current_user, producer_only: false)
            end
          end
          audit_operator_action!("mail_dismissed", permission: :reports_mailbox_manage, resource: email)
          redirect_to report_inbound_emails_path
        end

        def attachment
          email = scope.find(params[:id])
          attachment = email.attachments.find(params[:attachment_id])
          send_data ReportPrivateStorage.download!(attachment.blob), filename: attachment.filename.to_s, type: attachment.content_type,
                                                                     disposition: "attachment"
          response.set_header("X-Content-Type-Options", "nosniff")
        end

        private

        def scope = InboundEmail.where(organization: current_organization)

        def private_response
          response.cache_control.replace(no_store: true, private: true)
          response.set_header("Referrer-Policy", "no-referrer")
        end
      end
    end
  end
end

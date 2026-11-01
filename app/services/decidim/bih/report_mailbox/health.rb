# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module Health
        def self.summary(organization:, now: Time.current)
          cursors = MailboxCursor.where(organization:)
          emails = InboundEmail.where(organization:)
          reasons = []
          reasons << "consecutive_failures" if cursors.where("consecutive_failures >= 3").exists?
          reasons << "stale_poll" if cursors.empty? || cursors.where("last_success_at IS NULL OR last_success_at < ?", now - 30.minutes).exists?
          reasons << "processing_backlog" if emails.where(state: %w(stored processing)).where(created_at: ...(now - 30.minutes)).exists?
          reasons << "failed_message" if emails.where(state: "failed").exists?
          reasons << "authentication_failure" if cursors.where("last_error_class ILIKE ?", "%Auth%").exists?
          dispatches = ReportDispatch.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id })
          reasons << "unknown_dispatches" if dispatches.where(state: "unknown").exists?
          reasons << "smtp_authentication_failure" if dispatches.where("error_class ILIKE ?", "%Auth%").exists?
          begin
            Transport.settings! if Decidim::Bih.report_mail_transport == "gmail"
          rescue Transport::Unavailable
            reasons << "transport_unavailable"
          end
          { status: reasons.empty? ? "green" : "red", reasons: }
        end
      end
    end
  end
end

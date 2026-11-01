# frozen_string_literal: true

module Decidim
  module Bih
    class ReportReceivedEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        reference = extra.fetch("reference")
        report = Report.find_by(reference:, organization: user.organization) if extra["review_failure_proposal_id"].present?
        title = if report
                  task = ReportObligations.next_action(report)
                  status = task ? ReportObligations.label(task) : ReportStatusPresenter.label(report)
                  "#{reference}: #{status}"
                else
                  I18n.t("decidim.bih.report_staff_alert.title", reference:)
                end
        ActionController::Base.helpers.link_to(title, resource_path)
      end

      def resource_path
        Decidim::Bih::AdminEngine.routes.url_helpers.admin_bih_report_path(
          reference: extra.fetch("reference"), script_name: "/admin/bih"
        )
      end

      def resource_url
        URI.join("https://#{user.organization.host}", resource_path).to_s
      end

      def resource_title = nil
    end
  end
end

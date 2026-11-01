# frozen_string_literal: true

module Decidim
  module Bih
    class ReportCaseMessageEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.link_to(
          I18n.t("decidim.bih.report_case.new_message", reference: extra.fetch("reference")), resource_path
        )
      end

      def resource_path
        report = Report.find_by(id: extra["report_id"], organization: user.organization)
        return unless report
        return report.tokenized_status_path if report.author == user
        return unless OperatorAuthorization.allowed?(user, :reports_read, organization: user.organization)

        AdminEngine.routes.url_helpers.admin_bih_report_path(reference: report.reference, script_name: "/admin/bih")
      end

      def resource_url
        URI.join("https://#{user.organization.host}", resource_path).to_s if resource_path
      end

      def resource_title = nil
    end
  end
end

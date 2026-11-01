# frozen_string_literal: true

module Decidim
  module Bih
    class ReportStatusUpdateEvent < ReportCaseMessageEvent
      def notification_title
        report = Report.find_by(id: extra["report_id"], organization: user.organization)
        status = ReportStatusPresenter.label(report&.duplicate? ? report : extra.fetch("status"))
        title = I18n.t("decidim.bih.reporter_mailer.status_update.subject", reference: extra.fetch("reference"), status:)
        ActionController::Base.helpers.link_to(title, resource_path)
      end
    end
  end
end

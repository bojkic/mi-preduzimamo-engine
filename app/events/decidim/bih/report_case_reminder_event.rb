# frozen_string_literal: true

module Decidim
  module Bih
    class ReportCaseReminderEvent < ReportReceivedEvent
      def notification_title
        ActionController::Base.helpers.link_to(
          I18n.t("decidim.bih.report_case.overdue", reference: extra.fetch("reference")), resource_path
        )
      end
    end
  end
end

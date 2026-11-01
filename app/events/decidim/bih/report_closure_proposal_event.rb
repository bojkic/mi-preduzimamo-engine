# frozen_string_literal: true
module Decidim
  module Bih
    # Staff must decide whether administrative closure is justified. This event
    # makes no claim that the reported physical problem has been fixed.
    class ReportClosureProposalEvent < ReportReceivedEvent
      def notification_title
        ActionController::Base.helpers.link_to(
          I18n.t("decidim.bih.report_case.closure_proposed", reference: extra.fetch("reference")), resource_path
        )
      end
    end
  end
end

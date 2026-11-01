# frozen_string_literal: true

module Decidim
  module Bih
    class ReportShadowSweepCompletedEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent
      def notification_title
        count = extra.fetch("case_count").to_i
        ActionController::Base.helpers.link_to("Završen AI pregled #{count} prijava. Prijedlozi su spremni za pregled.", resource_path)
      end

      def resource_path = "/admin/bih/reports?view=all"

      def resource_url = URI.join("https://#{user.organization.host}", resource_path).to_s

      def resource_title = nil
    end
  end
end

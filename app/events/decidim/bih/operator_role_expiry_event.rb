# frozen_string_literal: true

module Decidim
  module Bih
    class OperatorRoleExpiryEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.sanitize(
          I18n.t(
            "decidim.bih.operator_role_expiry.notification",
            role: extra["role"].to_s.humanize,
            date: extra["expires_on"].to_s,
            days: extra["warning_days"].to_i,
            default: "Operatorska uloga %{role} ističe %{date}. Administrator je mora obnoviti uz novo obrazloženje; obnova nije automatska."
          )
        ).html_safe
      end

      def resource_path = nil

      def resource_url = nil

      def resource_title = nil
    end
  end
end

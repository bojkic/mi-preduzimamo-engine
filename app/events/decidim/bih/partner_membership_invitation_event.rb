# frozen_string_literal: true

module Decidim
  module Bih
    # In-app notification asking a citizen to accept or decline a public
    # organization affiliation. The payload contains no contact identifiers.
    class PartnerMembershipInvitationEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.sanitize(
          I18n.t(
            "decidim.bih.partner_memberships.events.invitation",
            organization: extra["organization"].to_s,
            role: I18n.t("decidim.bih.partner_memberships.roles.#{extra["role"]}")
          )
        ).html_safe
      end

      def resource_path = extra["organizations_url"].presence

      def resource_url = nil

      def resource_title = extra["organization"].to_s
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Publishes privacy-safe organization membership invitation notifications.
    # Delivery failures never change the pending consent state.
    class PartnerMembershipNotifications
      def self.publish_invitation(membership:, organizations_url:)
        user = membership.user
        return if user.blank?

        Decidim::EventsManager.publish(
          event: "decidim.events.bih.partner_membership.invitation",
          event_class: Decidim::Bih::PartnerMembershipInvitationEvent,
          resource: user,
          affected_users: [user],
          force_send: true,
          extra: {
            organization: membership.partner_profile.display_name,
            role: membership.role,
            organizations_url:
          }
        )
      rescue StandardError => e
        Rails.logger.error(
          "[PartnerMembership] invitation notification failed for membership #{membership.id}: " \
          "#{e.class}: #{e.message}"
        )
        nil
      end
    end
  end
end

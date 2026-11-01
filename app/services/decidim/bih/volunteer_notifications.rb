# frozen_string_literal: true

module Decidim
  module Bih
    # Small wrapper around Decidim notifications for volunteer review decisions.
    # Notification failures must not roll back review decisions or point awards.
    class VolunteerNotifications
      def self.publish(user:, kind:, status:, title:, reason: nil)
        return if user.blank?

        Decidim::EventsManager.publish(
          event: "decidim.events.bih.volunteer.decision",
          event_class: Decidim::Bih::VolunteerDecisionEvent,
          resource: user,
          affected_users: [user],
          force_send: true,
          extra: {
            kind: kind.to_s,
            status: status.to_s,
            title: title.to_s,
            reason: reason.to_s
          }
        )
      rescue StandardError => e
        Rails.logger.error(
          "[Volunteer] decision notification failed for user #{user&.id} " \
          "(#{e.class}: #{e.message}); review decision unaffected"
        )
        nil
      end
    end
  end
end

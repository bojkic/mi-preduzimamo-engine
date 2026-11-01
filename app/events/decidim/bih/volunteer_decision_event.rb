# frozen_string_literal: true

module Decidim
  module Bih
    # In-app notification for volunteer review decisions. The resource is the
    # affected user, so the notification does not need a participatory-space URL.
    class VolunteerDecisionEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.sanitize(
          I18n.t(
            "decidim.bih.volunteer.events.#{kind}.#{status}",
            title: title,
            reason: reason,
            default: I18n.t("decidim.bih.volunteer.events.default", title: title)
          )
        ).html_safe
      end

      def resource_path = nil

      def resource_url = nil

      def resource_title = nil

      private

      def kind
        extra["kind"].to_s
      end

      def status
        extra["status"].to_s
      end

      def title
        extra["title"].to_s
      end

      def reason
        extra["reason"].to_s
      end
    end
  end
end

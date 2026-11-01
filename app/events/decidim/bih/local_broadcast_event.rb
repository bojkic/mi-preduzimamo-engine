# frozen_string_literal: true

module Decidim
  module Bih
    # In-app bell notification delivered to each recipient of an operator-
    # initiated Komšiluk broadcast.
    #
    # IN-APP ONLY (NotificationEvent, no email). The message text and area name
    # come from the +extra+ payload supplied by BroadcastNotificationJob.
    #
    # PRIVACY: the title is generic — it addresses the citizen "kao stanovniku
    # vaše zajednice" and never names other members of the same komšiluk.
    # The notification never contains any other citizen's identity.
    class LocalBroadcastEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.sanitize(
          I18n.t(
            "decidim.bih.local_broadcast.events.notification_title",
            area_name: area_name,
            message: message_text
          )
        ).html_safe
      end

      # No participatory-space resource link — the resource is the user themselves.
      def resource_path = nil

      def resource_url = nil

      def resource_title = nil

      private

      def message_text
        # Sanitize to plain text — operator-entered freeform copy.
        ActionController::Base.helpers.strip_tags(extra["message"].to_s).strip
      end

      def area_name
        extra["area_name"].to_s
      end
    end
  end
end

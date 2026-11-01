# frozen_string_literal: true

module Decidim
  module Bih
    # In-app notification for an operator-to-user message.
    class OperatorMessageEvent < Decidim::Events::BaseEvent
      include Decidim::Events::NotificationEvent

      def notification_title
        ActionController::Base.helpers.sanitize(
          I18n.t(
            "decidim.bih.operator_messages.events.notification_title",
            subject: extra["subject"].to_s,
            body: extra["body"].to_s
          )
        ).html_safe
      end

      def resource_path = nil

      def resource_url = nil

      def resource_title = nil
    end
  end
end

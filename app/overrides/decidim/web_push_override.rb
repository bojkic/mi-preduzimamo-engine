# frozen_string_literal: true

module Decidim
  module Bih
    module WebPushSenderOverride
      def perform(notification, _title = nil)
        destination = notification.is_a?(Decidim::PushNotificationMessage) ? "conversations" : "notifications"
        return false unless notification

        return false unless proactive_push?(notification)

        receipt = PlatformDelivery.find_by(id: notification.extra.to_h["platform_delivery_id"], user: notification.user) if notification.respond_to?(:extra)
        WebPush.enqueue(notification.user, destination:, platform_delivery: receipt,
                                           topic: Messaging::NotificationTopic.for(notification),
                                           notification_id: notification.is_a?(Decidim::Notification) ? notification.id : nil)
      end

      private

      def proactive_push?(notification)
        return true unless notification.respond_to?(:extra)

        extra = (notification.extra || {}).stringify_keys
        return false if extra["proactive_delivery"] == false

        extra["proactive_channel"].nil? || extra["proactive_channel"] == "push"
      end
    end

    module WebPushSettingsOverride
      def meet_push_notifications_requirements?
        WebPush.enabled?
      end
    end

    module WebPushSubscriptionsOverride
      def add_subscription(params)
        keys = params[:keys]
        unless keys.respond_to?(:[]) && [:auth, :p256dh].all? { |key| keys[key].is_a?(String) && keys[key].present? && keys[key].bytesize <= 256 }
          raise Decidim::NotificationsSubscriptionsPersistor::UnsupportedPushSubscriptionEndpointError
        end

        user.with_lock { super }
      end

      def delete_subscription(auth_key)
        user.with_lock { super }
      end
    end

    module WebPushSubscriptionAccess
      extend ActiveSupport::Concern

      included do
        before_action :authenticate_user!
        before_action :check_push_organization
      end

      private

      def check_push_organization
        head :forbidden unless current_user&.decidim_organization_id == current_organization.id
      end
    end
  end
end

Decidim::SendPushNotification.prepend(Decidim::Bih::WebPushSenderOverride)
Decidim::NotificationsSettingsForm.prepend(Decidim::Bih::WebPushSettingsOverride)
Decidim::NotificationsSubscriptionsPersistor.prepend(Decidim::Bih::WebPushSubscriptionsOverride)
Decidim::NotificationsSubscriptionsController.include(Decidim::Bih::WebPushSubscriptionAccess)

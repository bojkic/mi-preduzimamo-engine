# frozen_string_literal: true

module Decidim
  module Bih
    # Delivery-report reads only. This job can never invoke a send or failover.
    class AccountNotificationReconciliationJob < Decidim::ApplicationJob
      self.log_arguments = false
      queue_as :integrations
      OFFSETS = [1.minute, 5.minutes, 15.minutes, 1.hour, 6.hours, 23.hours].freeze

      def perform(notification_id, attempt = 0)
        return unless attempt.is_a?(Integer) && attempt.between?(0, OFFSETS.length - 1)

        notification = AccountNotification.find_by(id: notification_id)
        return unless reconcilable?(notification)

        begin
          AccountNotifications.reconcile!(notification)
        rescue Infobip::Error => e
          Rails.logger.info("[AccountNotificationReconciliationJob] #{notification.id}: #{e.class}")
        end
        return if notification.reload.status == "delivered" || attempt + 1 >= OFFSETS.length

        self.class.set(wait_until: notification.created_at + OFFSETS.fetch(attempt + 1)).perform_later(notification.id, attempt + 1)
      end

      private

      def reconcilable?(notification)
        notification && %w(accepted unknown sending).include?(notification.status) &&
          notification.provider_message_ids.any? && notification.created_at >= 24.hours.ago
      end
    end
  end
end

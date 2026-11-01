# frozen_string_literal: true

module Decidim
  module Bih
    module PlatformNotificationReceiptOverride
      def destroy
        notification = current_user.notifications.find(params[:id])
        receipt = PlatformDelivery.find_by(id: notification.extra.to_h["platform_delivery_id"], user: current_user)
        return super unless receipt

        receipt.with_lock do
          super
          receipt.acknowledge!("inbox_read")
        end
      end

      def read_all
        ids = notifications.map { |notification| notification.extra.to_h["platform_delivery_id"] }.compact
        PlatformDelivery.transaction do
          receipts = PlatformDelivery.where(id: ids, user: current_user).order(:id).lock.to_a
          super
          receipts.each { |receipt| receipt.acknowledge!("inbox_read") }
        end
      end
    end
  end
end

Decidim::NotificationsController.prepend(Decidim::Bih::PlatformNotificationReceiptOverride)

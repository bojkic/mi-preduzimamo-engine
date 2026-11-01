# frozen_string_literal: true

module Decidim
  module Bih
    class KomsilukNoticeDeliveryJob < Decidim::ApplicationJob
      queue_as :events
      self.log_arguments = false

      def perform(receipt_id)
        receipt = PlatformDelivery.find_by(id: receipt_id)
        return unless receipt&.komsiluk_post

        dispatch = -> { deliver(receipt) }
        WebPush.delivery_guard ? WebPush.delivery_guard.call(receipt:, &dispatch) : dispatch.call
      end

      private

      def deliver(receipt)
        delivered = Komsiluk::NoticePublishing.with_current_receipt(receipt) do
          next if receipt.notification_dispatched_at

          post = receipt.komsiluk_post
          unless receipt.inbox_created_at
            extra = { "category" => post.category, "board_url" => Komsiluk::NoticePublishing.board_url(post),
                      "organization_id" => receipt.decidim_organization_id, "platform_delivery_id" => receipt.id,
                      "notification_topic" => "neighborhood_info", "proactive_delivery" => false,
                      "notice_update" => receipt.fallback_context["notice_update"] == true,
                      "publication_revision" => receipt.publication_revision }
            notification = Decidim::NotificationGeneratorForRecipient.new(
              "decidim.events.bih.komsiluk_post", KomsilukPostEvent, receipt.user, receipt.user, "affected_user", extra
            ).generate
            receipt.update!(inbox_created_at: Time.current, notification_id: notification&.id)
          end
          WebPush.enqueue(receipt.user, topic: :neighborhood_info, platform_delivery: receipt)
          receipt.update!(notification_dispatched_at: Time.current)
        end
        return if delivered || receipt.cancelled_at

        receipt.update!(cancelled_at: Time.current, cancellation_reason: "publication_or_membership_changed")
      end
    end
  end
end

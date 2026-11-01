# frozen_string_literal: true

module Decidim
  module Bih
    class WebPushTestsController < Decidim::ApplicationController
      include CurrentOrganizationUser

      before_action :authenticate_user!

      def create
        user = current_organization_user
        return head :forbidden unless user
        return head :service_unavailable unless WebPush.enabled?

        fingerprint = params[:fingerprint].to_s
        return head :unprocessable_entity unless user.notifications_subscriptions.values.any? { |item| WebPush.fingerprint(item) == fingerprint }

        # Atomic Redis NX prevents concurrent requests bypassing the cooldown.
        allowed = Sidekiq.redis { |redis| redis.set("bih:web_push_test:#{user.id}", "1", nx: true, ex: 60) }
        return head :too_many_requests unless allowed

        WebPushDeliveryJob.perform_later(user.id, fingerprint)
        head :accepted
      end
    end
  end
end

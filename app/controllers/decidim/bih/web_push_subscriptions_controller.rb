# frozen_string_literal: true

module Decidim
  module Bih
    # The core DELETE route embeds the subscription auth secret in the URL.
    # Use a fingerprint in the request body so access logs contain no credential.
    class WebPushSubscriptionsController < Decidim::ApplicationController
      include CurrentOrganizationUser

      before_action :authenticate_user!

      def destroy
        user = current_organization_user
        return head :forbidden unless user

        fingerprint = params[:fingerprint].to_s
        user.with_lock do
          settings = user.notification_settings.deep_dup
          settings["subscriptions"] = (settings["subscriptions"] || {}).reject do |_key, subscription|
            WebPush.fingerprint(subscription) == fingerprint
          end
          user.update!(notification_settings: settings)
        end
        head :no_content
      end
    end
  end
end

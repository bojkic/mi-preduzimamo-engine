# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      class SettingsView
        def initialize(user:, organization:)
          @user = user
          @organization = organization
        end

        attr_reader :user, :organization

        def topics = TopicPreferences::TOPICS

        def enabled?(topic) = TopicPreferences.enabled?(user, topic:)

        def verified_phone? = VerifiedPhone.phone_for(user:, organization:).present?

        def proven_email? = EmailConfirmation.confirmed?(user)

        def push_available? = WebPush.enabled?

        def push_devices
          user.notifications_subscriptions.filter_map do |_key, subscription|
            WebPush.fingerprint(subscription)
          end
        end
      end
    end
  end
end

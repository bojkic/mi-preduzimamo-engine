# frozen_string_literal: true

module Decidim
  module Bih
    # Keep the platform inbox available independently of proactive topics.
    # Preserve the core generator's resource/access checks in its private
    # generate_notification_for method; only the old delivery scope is removed.
    module PlatformNotificationGeneratorOverride
      def generate
        return unless resource && event_class.types.include?(:notification)

        seen = {}
        [[affected_users, :affected_user], [followers, :follower]].each do |recipients, role|
          recipients.each do |recipient|
            next if seen[recipient.id]

            seen[recipient.id] = true
            generate_notification_for(recipient, user_role: role)
          end
        end
      end
    end
  end
end

Decidim::NotificationGenerator.prepend(Decidim::Bih::PlatformNotificationGeneratorOverride)

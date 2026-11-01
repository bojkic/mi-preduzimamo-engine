# frozen_string_literal: true

module Decidim
  module Bih
    # Sends transition notifications without storing private reasons or contacts.
    class CommunityContributionNotifications
      def self.publish(transition:, item:, affected_users:, path:)
        return unless defined?(Decidim::EventsManager)

        Array(affected_users).compact.uniq(&:id).each do |user|
          Decidim::EventsManager.publish(
            event: "decidim.events.bih.community_contribution.#{transition}",
            event_class: Decidim::Bih::CommunityContributionEvent,
            resource: user,
            affected_users: [user],
            force_send: true,
            extra: { transition:, item: item.to_s.first(160), path: }
          )
        end
      rescue StandardError => e
        Rails.logger&.error("[CommunityContributionNotifications] #{transition} failed: #{e.class}") if Rails.respond_to?(:logger)
        nil
      end

      def self.public_path(suffix)
        mount = if Decidim::Bih.respond_to?(:normalized_public_mount_path)
                  Decidim::Bih.normalized_public_mount_path
                else
                  "/biceriseno"
                end
        "#{mount == "/" ? "" : mount}/#{suffix.to_s.delete_prefix("/")}"
      end
    end
  end
end

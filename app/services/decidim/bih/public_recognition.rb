# frozen_string_literal: true

module Decidim
  module Bih
    # User-level preference for public MI recognition on Decidim profiles.
    # Default is enabled to preserve the existing public contribution display.
    module PublicRecognition
      KEY = "bih_public_recognition"

      module_function

      def enabled_for?(user)
        return false unless user

        data = user.extended_data || {}
        return true unless data.has_key?(KEY)

        ActiveModel::Type::Boolean.new.cast(data[KEY])
      end

      def set_enabled!(user, enabled)
        data = (user.extended_data || {}).dup
        data[KEY] = ActiveModel::Type::Boolean.new.cast(enabled)
        user.update!(extended_data: data)
        invalidate_leaderboard_cache(user)
      end

      # Fresh membership fingerprint also handles role expiry without a write.
      # Hydration still applies the current cohort, so a warmed cache cannot
      # disclose someone who has opted out or become staff since it was built.
      def cohort_version(organization)
        users = Decidim::User.where(organization:)
        roles = Decidim::Bih::OperatorRole.active.where(organization:)
        [users.count, users.maximum(:updated_at)&.utc&.iso8601(6),
         roles.count, roles.maximum(:updated_at)&.utc&.iso8601(6)].join(":")
      end

      def invalidate_leaderboard_cache(user)
        organization_id = user.respond_to?(:decidim_organization_id) ? user.decidim_organization_id : nil
        organization_id ||= user.organization&.id if user.respond_to?(:organization)
        return unless organization_id

        Rails.cache.delete_matched("decidim_bih/leaderboard/#{organization_id}/*")
      rescue NotImplementedError, StandardError => e
        Rails.logger.warn("[PublicRecognition] leaderboard cache invalidation failed: #{e.class}")
      end
    end
  end
end

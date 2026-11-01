# frozen_string_literal: true

module Decidim
  module Bih
    # Compact menu activity uses Core0.32's current-user-aware visibility query.
    class MenuActivityCell < Decidim::ContentBlocks::LastActivityCell
      def show
        return if current_user.blank? && current_organization&.force_users_to_authenticate_before_access_organization

        super
      end

      private

      def activities_to_show
        4
      end

      def cache_hash
        ["decidim/bih/menu_activity", current_organization.cache_key_with_version,
         Digest::SHA256.hexdigest(valid_activities.map(&:cache_key_with_version).to_s), I18n.locale.to_s].join(Decidim.cache_key_separator)
      end
    end
  end
end

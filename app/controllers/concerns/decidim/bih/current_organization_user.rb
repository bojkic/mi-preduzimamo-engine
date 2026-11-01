# frozen_string_literal: true

module Decidim
  module Bih
    # Resolves the signed-in user only when they belong to the current
    # organization. Public engine workflows must use this instead of raw
    # `current_user` whenever they create records, award points, or expose
    # owner-only controls.
    module CurrentOrganizationUser
      extend ActiveSupport::Concern

      included do
        if respond_to?(:helper_method)
          helper_method :current_organization_user,
                        :current_organization_user_signed_in?,
                        :current_organization_user_verified?
        end
      end

      private

      def current_organization_user
        return nil unless respond_to?(:current_user, true) && respond_to?(:current_organization, true)

        user = current_user
        organization = current_organization
        Decidim::Bih.organization_scoped_user(user, organization)
      end

      def current_organization_user_signed_in?
        !current_organization_user.nil?
      end

      def current_organization_user_verified?
        user = current_organization_user
        return false unless user && defined?(Decidim::Authorization)

        Decidim::Authorization.where(user: user).where.not(granted_at: nil).exists?
      end
    end
  end
end

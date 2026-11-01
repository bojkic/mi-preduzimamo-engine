# frozen_string_literal: true

module Decidim
  module Bih
    # Permission checker for custom BIH operator workflows.
    class OperatorAuthorization
      class << self
        def allowed?(user, permission, organization:, resource: nil)
          new(user:, organization:, resource:).allowed?(permission)
        end

        def role_for(user, permission, organization:)
          return nil unless eligible_user?(user, organization)
          return "admin" if user.admin?

          OperatorRole
            .active_for(user, organization)
            .for_permission(permission)
            .order(expires_at: :desc, id: :desc)
            .first&.role
        end

        def permissions_for(user, organization:)
          return [] unless eligible_user?(user, organization)
          return OperatorRole::ALL_PERMISSIONS if user.admin?

          OperatorRole.active_for(user, organization).flat_map(&:permissions).uniq
        end

        def operator?(user, organization:)
          return false unless eligible_user?(user, organization)

          OperatorRole.operator?(user, organization)
        end

        private

        # Every entry point must check the tenant and account state before
        # granting the administrator shortcut or consulting delegated roles.
        def eligible_user?(user, organization)
          return false if user.blank? || organization.blank?
          return false unless user.respond_to?(:organization) && user.organization == organization

          !(user.try(:deleted?) || user.try(:blocked?) || user.try(:blocked_at).present?)
        end
      end

      def initialize(user:, organization:, resource: nil)
        @user = user
        @organization = organization
        @resource = resource
      end

      def allowed?(permission)
        return false if user.blank? || organization.blank?
        return false unless same_organization_user?
        return false if user.try(:deleted?) || user.try(:blocked?) || user.try(:blocked_at).present?
        return true if user.admin?

        roles = OperatorRole.active_for(user, organization).for_permission(permission)
        return roles.exists? unless resource && %w(komsiluk_posts_read komsiluk_posts_moderate).include?(permission.to_s)
        return false unless resource.respond_to?(:komsiluk_id) && resource.organization == organization

        roles.any? { |role| role.covers_komsiluk?(resource.komsiluk_id) }
      end

      private

      attr_reader :user, :organization, :resource

      def same_organization_user?
        user.respond_to?(:organization) && user.organization == organization
      end
    end
  end
end

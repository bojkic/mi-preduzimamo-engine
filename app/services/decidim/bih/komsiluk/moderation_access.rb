# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      # A scoped moderator can enter the queue but can only enumerate or mutate
      # posts and areas covered by an active grant in this organization.
      class ModerationAccess
        def initialize(user:, organization:)
          @user = user
          @organization = organization
        end

        def posts
          scope = KomsilukPost.where(organization: @organization)
          unrestricted? ? scope : scope.where(komsiluk_id: area_ids)
        end

        def areas
          scope = LocalArea.komsiluci.where(organization: @organization)
          unrestricted? ? scope : scope.where(id: area_ids)
        end

        def unrestricted?
          return false unless same_organization?
          return true if @user.admin?

          grants.any? { |grant| grant.area_scope == "all" }
        end

        def area_ids
          return [] unless same_organization?

          grants.flat_map { |grant| Array(grant.komsiluk_ids).map(&:to_i) }.uniq
        end

        private

        def same_organization?
          @user.present? && @organization.present? && @user.organization == @organization
        end

        def grants
          @grants ||= OperatorRole.active_for(@user, @organization).for_permission(:komsiluk_posts_read).to_a
        end
      end
    end
  end
end

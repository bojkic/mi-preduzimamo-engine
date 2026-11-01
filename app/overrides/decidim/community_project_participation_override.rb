# frozen_string_literal: true

# A moderated community-support project lives in an unpublished Decidim
# process so it cannot be confused with participatory budgeting. Its canonical
# custom detail still supports ordinary Decidim comments/follows while the
# technical component is active. Genuine Budget projects retain Decidim's
# native participatory-space rules.
module Decidim
  module Bih
    module CommunityProjectParticipationOverride
      def can_participate?(user)
        return super unless approved_community_support_project?

        component.published? && !participatory_space.published? && user.present?
      end

      def can_participate_in_space?(user)
        can_participate?(user)
      end

      private

      def approved_community_support_project?
        return false unless Decidim::Bih::PartnerProjectSubmission.table_exists?

        Decidim::Bih::PartnerProjectSubmission.approved.exists?(
          organization:,
          project: self
        )
      rescue ActiveRecord::StatementInvalid
        false
      end
    end
  end
end

Decidim::Budgets::Project.prepend(
  Decidim::Bih::CommunityProjectParticipationOverride
)

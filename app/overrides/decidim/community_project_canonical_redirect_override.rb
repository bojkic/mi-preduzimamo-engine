# frozen_string_literal: true

# Keep one citizen-facing project surface while retaining native Budgets
# projects as the canonical records. The dedicated community-project budget
# index redirects to /projekti, and native detail/search links for projects
# created through the moderated partner workflow redirect to /projekti/:id.
# Legacy participatory-budget projects keep their native pages and voting flow.
module Decidim
  module Bih
    module CommunityProjectCanonicalRedirectOverride
      def index
        super
        return if performed?
        return unless canonical_community_budget?

        redirect_to Decidim::Bih.public_path("projekti"), status: :moved_permanently
      end

      def show
        super
        return if performed?
        return unless moderated_community_project?

        # Keep this temporary so route changes are never cached by browsers or
        # intermediaries. The approved native project remains a durable public
        # transparency record even when active fundraising/help is later paused.
        redirect_to Decidim::Bih.public_path("projekti/#{project.id}"), status: :found
      end

      private

      def canonical_community_budget?
        return false unless budget
        return false unless Decidim::Bih::Setting.table_available?

        configured_id = Decidim::Bih::Setting
                        .namespace_for(current_organization, "community_projects")
                        .fetch("budget_id", nil)
        configured_id.to_i == budget.id
      end

      def moderated_community_project?
        return false unless project
        return false unless Decidim::Bih::PartnerProjectSubmission.table_exists?

        # The native/custom identity is durable once moderation materializes a
        # native project. Link activation and partner visibility only control
        # active catalog, fundraising and help actions; they do not retract the
        # already-approved public project record.
        Decidim::Bih::PartnerProjectSubmission.exists?(
          organization: current_organization,
          project:
        )
      rescue ActiveRecord::StatementInvalid
        false
      end
    end
  end
end

Decidim::Budgets::ProjectsController.prepend(Decidim::Bih::CommunityProjectCanonicalRedirectOverride)

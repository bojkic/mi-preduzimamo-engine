# frozen_string_literal: true

# Approved partner projects are permanent public transparency records. Native
# Budgets administration may still pause the whole component as explicit
# incident control, but it cannot individually trash a project materialized by
# the LFBN moderation workflow.
module Decidim
  module Bih
    module PartnerProjectDeletionGuardOverride
      def soft_delete
        return super unless approved_partner_project?(trashable_deleted_resource)

        enforce_permission_to(
          :soft_delete,
          trashable_deleted_resource_type,
          trashable_deleted_resource:
        )
        flash[:alert] = I18n.t(
          "decidim.bih.admin.community_contributions.project_delete_blocked"
        )
        redirect_to_resource_index
      end

      private

      def approved_partner_project?(project)
        return false if project.blank? || !Decidim::Bih::PartnerProjectSubmission.table_exists?

        Decidim::Bih::PartnerProjectSubmission.approved.exists?(
          organization: current_organization,
          project:
        )
      rescue ActiveRecord::StatementInvalid
        true
      end
    end
  end
end

Decidim::Budgets::Admin::ProjectsController.prepend(
  Decidim::Bih::PartnerProjectDeletionGuardOverride
)

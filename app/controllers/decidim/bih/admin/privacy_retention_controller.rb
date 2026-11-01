# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Read-only privacy retention status for operators.
      class PrivacyRetentionController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:privacy_retention_read) }

        def index
          @summary = Decidim::Bih::Admin::RetentionSummary.new(organization: current_organization).summary
          @retention_approval = Decidim::Bih::GovernanceApproval.latest_by_kind(current_organization)["privacy_retention"]
          @retention_approval_current = @retention_approval&.current_approval?
          @retention_counts_match = @retention_approval_current &&
                                    @retention_approval.metadata.has_key?("dry_run_total") &&
                                    @retention_approval.scope_key == @summary[:scope_key] &&
                                    @retention_approval.metadata["dry_run_total"].to_i == @summary[:total].to_i
        end
      end
    end
  end
end

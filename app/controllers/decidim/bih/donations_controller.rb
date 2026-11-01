# frozen_string_literal: true

module Decidim
  module Bih
    # Public, anonymous aggregate donation-transparency surface. Project
    # discovery and checkout actions live on the unified /projekti catalog.
    #
    # The totals come from the host-wired Decidim::Bih.donations_provider (the
    # cached Odoo mirror) — the read NEVER blocks on Odoo and degrades to a
    # zeroed figure when no provider is configured or the cache is cold.
    #
    # GET /donacije
    class DonationsController < Decidim::ApplicationController
      def show
        provider = Decidim::Bih.donations_provider_for(organization: current_organization)
        @totals = provider&.totals || Decidim::Bih::Odoo::DonationTotals::Result.zero
        @currency_label = provider&.currency_label || "KM"
        @project_mappings = provider.respond_to?(:project_mappings) ? Array(provider_project_mappings(provider)) : []
        @community_project_mappings, @participatory_budget_mappings = @project_mappings.partition do |mapping|
          community_project_mapping?(mapping)
        end
        @unallocated_amount = unallocated_amount
      end

      private

      def provider_project_mappings(provider)
        provider.project_mappings(organization: current_organization)
      rescue ArgumentError
        # Backwards compatibility for host providers and test doubles that
        # implement the original zero-argument optional method.
        provider.project_mappings
      end

      # Donations with no Odoo project attribution: grand total minus the sum of
      # the per-project totals, clamped at >= 0. Surfaced as an explicit "Opšti
      # fond (neraspoređeno)" line so the breakdown reconciles with the total.
      def unallocated_amount
        project_totals = @project_mappings.map do |project|
          totals = project_field(project, :totals)
          project_field(totals, :total)
        end

        Decidim::Bih::DonationReconciliation.unallocated_amount(
          grand_total: @totals.total,
          project_totals:
        )
      end

      def project_field(object, key)
        if object.respond_to?(key)
          object.public_send(key)
        elsif object.respond_to?(:[])
          object[key] || object[key.to_s]
        end
      rescue KeyError, NameError, TypeError
        nil
      end

      def community_project_mapping?(mapping)
        explicit = project_field(mapping, :community_project)
        return explicit if explicit == true || explicit == false

        project_id = project_field(mapping, :decidim_project_id).to_i
        return false unless project_id.positive? && Decidim::Bih::PartnerProjectSubmission.table_exists?

        Decidim::Bih::PartnerProjectSubmission.approved.exists?(
          organization: current_organization,
          decidim_budgets_project_id: project_id
        )
      rescue ActiveRecord::StatementInvalid
        false
      end

      helper_method def donation_project_path(mapping)
        project_id = project_field(mapping, :decidim_project_id).to_i
        return community_projects_path unless project_id.positive?
        return community_project_path(project_id) if community_project_mapping?(mapping)

        project = Decidim::Budgets::Project.find_by(id: project_id)
        return community_project_path(project_id) unless project&.organization == current_organization

        Decidim::EngineRouter.main_proxy(project.component).budget_project_path(
          budget_id: project.budget.id,
          id: project.id
        )
      rescue StandardError
        community_project_path(project_id)
      end
    end
  end
end

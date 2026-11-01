# frozen_string_literal: true

require "erb"

module Decidim
  module Bih
    # Atomically approves a submitted partner project, creates the canonical
    # native Budgets project and donation link, and reconciles the configured
    # budget total. The native Budget is a hidden storage seam, not a public
    # participatory-budget product. The target is an operator-owned
    # per-organization Setting, never a public request parameter.
    class ApprovePartnerProjectSubmission
      SETTINGS_NAMESPACE = "community_projects"
      BUDGET_ID_KEY = "budget_id"

      def self.call(submission, reviewer:, campaign_key:, **dependencies)
        new(submission, reviewer:, campaign_key:, dependencies:).call
      end

      def initialize(submission, reviewer:, campaign_key:, dependencies:)
        @submission = submission
        @reviewer = reviewer
        @campaign_key = campaign_key.to_s.strip.downcase
        @setting_class = dependencies.fetch(:setting_class) { Decidim::Bih::Setting }
        @budget_class = dependencies.fetch(:budget_class) { Decidim::Budgets::Budget }
        @project_class = dependencies.fetch(:project_class) { Decidim::Budgets::Project }
        @link_class = dependencies.fetch(:link_class) { Decidim::Bih::ProjectDonationLink }
        @profile_class = dependencies.fetch(:profile_class) { Decidim::Bih::PartnerProfile }
        @traceability = dependencies.fetch(:traceability) { Decidim.traceability }
        @campaign_validator = dependencies.fetch(:campaign_validator) { method(:default_campaign_ready?) }
      end

      def call
        status, budget = preflight
        return status if status

        result = approve!(budget)
        notify_representative if result == :ok
        result
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
        :invalid
      end

      private

      attr_reader :submission, :reviewer, :campaign_key, :setting_class, :budget_class,
                  :project_class, :link_class, :profile_class, :traceability, :campaign_validator

      def preflight
        status = guard_status
        return [status, nil] if status
        return [:campaign_unverified, nil] unless campaign_ready?

        budget = configured_budget
        return [:invalid, nil] unless community_storage_budget?(budget)

        [nil, budget]
      end

      def approve!(budget)
        result = :ok
        submission.class.transaction do
          budget.lock! if budget.respond_to?(:lock!)
          submission.lock! if submission.respond_to?(:lock!)
          submission.partner_profile.lock! if submission.partner_profile.respond_to?(:lock!)

          locked_status = locked_guard_status
          if locked_status
            result = locked_status
            next
          end
          unless campaign_ready?
            result = :campaign_unverified
            next
          end

          project = create_project!(budget)
          link_class.create!(organization: submission.organization, project:, campaign_key:, active: true)
          submission.update!(
            review_status: "approved",
            project:,
            reviewer:,
            reviewed_at: Time.current,
            rejection_reason: nil
          )
          reconcile_budget_total!(budget)
        end
        result
      end

      def guard_status
        return :missing if submission.blank?
        return :already if submission.approved?
        return :invalid unless submission.submitted?
        return :invalid unless partner_profile_publicly_eligible?

        :invalid unless reviewer_belongs_to_organization? && valid_campaign_key?
      end

      def reviewer_belongs_to_organization?
        reviewer.present? && reviewer.organization == submission.organization
      end

      def locked_guard_status
        return :already if submission.approved?
        return :invalid unless submission.submitted?

        :invalid unless partner_profile_publicly_eligible?
      end

      def partner_profile_publicly_eligible?
        profile = submission.partner_profile
        return false unless profile

        profile_class.publicly_visible.exists?(
          id: profile.id,
          decidim_organization_id: submission.organization.id
        )
      end

      def valid_campaign_key?
        campaign_key.length <= link_class::MAX_CAMPAIGN_KEY_LENGTH &&
          campaign_key.match?(link_class::CAMPAIGN_KEY_PATTERN)
      end

      def campaign_ready?
        campaign_validator.call(campaign_key, submission.organization) == true
      rescue StandardError
        false
      end

      def default_campaign_ready?(key, organization)
        return false unless Decidim::Bih.respond_to?(:donations_provider_for)

        provider = Decidim::Bih.donations_provider_for(organization:)
        return false unless provider&.respond_to?(:campaign_ready?)

        provider.campaign_ready?(key, organization:)
      end

      def configured_budget
        raw_id = setting_class.namespace_for(submission.organization, SETTINGS_NAMESPACE)[BUDGET_ID_KEY]
        id = raw_id.to_i
        return if id <= 0

        budget_class.find_by(id:)
      end

      def community_storage_budget?(budget)
        return false if budget.blank? || budget.organization != submission.organization

        component = budget.component
        space = component&.participatory_space
        component&.published? &&
          space&.organization == submission.organization &&
          !space.published?
      rescue StandardError
        false
      end

      def create_project!(budget)
        traceability.create!(
          project_class,
          reviewer,
          {
            budget:,
            title: localized(submission.title),
            description: localized(escaped_description),
            budget_amount: submission.budget_amount,
            address: submission.address
          },
          visibility: "all"
        )
      end

      def reconcile_budget_total!(budget)
        total = budget.projects.sum(:budget_amount)
        traceability.update!(budget, reviewer, { total_budget: total }, visibility: "all")
      end

      def localized(value)
        organization = submission.organization
        locales = Array(organization.available_locales).map(&:to_s)
        locales = [organization.default_locale.to_s] if locales.empty?
        locales.index_with { value }
      end

      def escaped_description
        ERB::Util.html_escape(submission.description).gsub(/\r?\n/, "<br>")
      end

      def notify_representative
        project_id = submission.decidim_budgets_project_id if submission.respond_to?(:decidim_budgets_project_id)
        project_path = project_id.present? ? "projekti/#{project_id}" : "projekti"

        CommunityContributionNotifications.publish(
          transition: "project_approved",
          item: submission.title,
          affected_users: [submission.representative],
          path: CommunityContributionNotifications.public_path(project_path)
        )
      rescue StandardError => e
        Rails.logger&.error("[ApprovePartnerProjectSubmission] notification failed: #{e.class}") if Rails.respond_to?(:logger)
        nil
      end
    end
  end
end

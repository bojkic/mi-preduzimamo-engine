# frozen_string_literal: true

module Decidim
  module Bih
    # The single canonical provider mapping for a native Budgets project. The
    # host converts campaign_key to a provider URL; the reusable engine stores
    # neither provider credentials nor provider-specific URLs.
    class ProjectDonationLink < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_project_donation_links"

      CAMPAIGN_KEY_PATTERN = /\A[a-z0-9][a-z0-9_-]*\z/
      MAX_CAMPAIGN_KEY_LENGTH = 100

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"
      belongs_to :project,
                 class_name: "Decidim::Budgets::Project",
                 foreign_key: "decidim_budgets_project_id"
      has_one :partner_project_submission,
              class_name: "Decidim::Bih::PartnerProjectSubmission",
              primary_key: :decidim_budgets_project_id,
              foreign_key: :decidim_budgets_project_id,
              inverse_of: :project_donation_link,
              dependent: :restrict_with_exception

      before_validation :normalize_campaign_key

      validates :campaign_key,
                presence: true,
                length: { maximum: MAX_CAMPAIGN_KEY_LENGTH },
                format: { with: CAMPAIGN_KEY_PATTERN },
                uniqueness: { scope: :decidim_organization_id, case_sensitive: true }
      validates :project, uniqueness: { scope: :decidim_organization_id }
      validate :project_belongs_to_organization

      scope :active, -> { where(active: true) }

      private

      def normalize_campaign_key
        self.campaign_key = campaign_key.to_s.strip.downcase
      end

      def project_belongs_to_organization
        return if project.blank? || organization.blank? || project.organization == organization

        errors.add(:project, :invalid)
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # A private proposal from a verified partner profile. LFBN review creates a
    # native Budgets project; only that approved project is publicly rendered.
    class PartnerProjectSubmission < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_partner_project_submissions"

      REVIEW_STATUSES = %w(draft submitted changes_requested approved rejected).freeze
      MAX_TITLE_LENGTH = 160
      MAX_DESCRIPTION_LENGTH = 5_000
      MAX_ADDRESS_LENGTH = 500
      MAX_REJECTION_REASON_LENGTH = 1_000
      MAX_BUDGET_AMOUNT = 9_223_372_036_854_775_807

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"
      belongs_to :partner_profile,
                 class_name: "Decidim::Bih::PartnerProfile",
                 inverse_of: :project_submissions
      belongs_to :representative,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id",
                 optional: true
      belongs_to :reviewer,
                 class_name: "Decidim::User",
                 foreign_key: "reviewed_by_id",
                 optional: true
      belongs_to :project,
                 class_name: "Decidim::Budgets::Project",
                 foreign_key: "decidim_budgets_project_id",
                 optional: true
      has_one :project_donation_link,
              class_name: "Decidim::Bih::ProjectDonationLink",
              primary_key: :decidim_budgets_project_id,
              foreign_key: :decidim_budgets_project_id,
              dependent: :restrict_with_exception,
              inverse_of: :partner_project_submission

      before_validation :normalize_fields

      validates :title, presence: true, length: { maximum: MAX_TITLE_LENGTH }
      validates :description, presence: true, length: { maximum: MAX_DESCRIPTION_LENGTH }
      validates :budget_amount,
                presence: true,
                numericality: {
                  only_integer: true,
                  greater_than: 0,
                  less_than_or_equal_to: MAX_BUDGET_AMOUNT
                }
      validates :address, length: { maximum: MAX_ADDRESS_LENGTH }, allow_blank: true
      validates :representative, presence: true, on: :create
      validates :review_status, inclusion: { in: REVIEW_STATUSES }
      validates :rejection_reason, length: { maximum: MAX_REJECTION_REASON_LENGTH }, allow_blank: true
      validate :dates_are_ordered
      validate :associations_belong_to_organization
      validate :partner_profile_is_verified, on: :create
      validate :representative_is_content_manager, on: :create
      validate :project_matches_approval_state, if: :project_approval_validation_required?

      scope :pending_review, -> { where(review_status: "submitted") }
      scope :approved, -> { where(review_status: "approved") }

      def draft?
        review_status == "draft"
      end

      def submitted?
        review_status == "submitted"
      end

      def changes_requested?
        review_status == "changes_requested"
      end

      def approved?
        review_status == "approved"
      end

      def rejected?
        review_status == "rejected"
      end

      def represented_by_content_manager?(user)
        return false if user.blank? || partner_profile.blank?

        membership = partner_profile.memberships.accepted.find_by(user:)
        membership&.content_manager? || false
      end

      alias represented_by_manager? represented_by_content_manager?

      private

      def normalize_fields
        self.title = title.to_s.strip
        self.description = description.to_s.strip
        self.address = address.to_s.strip.presence
        self.review_status = review_status.to_s.presence || "draft"
        self.rejection_reason = rejection_reason.to_s.strip.presence
      end

      def dates_are_ordered
        return if starts_on.blank? || ends_on.blank? || ends_on >= starts_on

        errors.add(:ends_on, :greater_than_or_equal_to, count: starts_on)
      end

      def associations_belong_to_organization
        return if organization.blank?

        validate_organization_of(:partner_profile, partner_profile)
        validate_organization_of(:representative, representative)
        validate_organization_of(:reviewer, reviewer)
        validate_organization_of(:project, project)
      end

      def validate_organization_of(name, record)
        errors.add(name, :invalid) if record.present? && record.organization != organization
      end

      def partner_profile_is_verified
        return if partner_profile.blank? || partner_profile.verified?

        errors.add(:partner_profile, :unverified)
      end

      def representative_is_content_manager
        return if representative.blank? || partner_profile.blank?
        return if represented_by_content_manager?(representative)

        errors.add(:representative, :invalid)
      end

      def project_matches_approval_state
        errors.add(:project, :invalid) if project.present? && !approved?
        errors.add(:project, :blank) if approved? && project.blank?
      end

      def project_approval_validation_required?
        new_record? || will_save_change_to_review_status? || will_save_change_to_decidim_budgets_project_id?
      end
    end
  end
end

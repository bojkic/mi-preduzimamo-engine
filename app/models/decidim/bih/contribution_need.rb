# frozen_string_literal: true

require "bigdecimal"

module Decidim
  module Bih
    # A moderated non-cash request from a verified organization. People and
    # specialist skills remain VolunteerOpportunity concerns; monetary requests
    # remain native Budgets projects with donation links.
    class ContributionNeed < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_contribution_needs"

      NEED_TYPES = %w(equipment materials space transport other).freeze
      REVIEW_STATUSES = %w(pending approved rejected).freeze
      FULFILLMENT_STATUSES = %w(open fulfilled cancelled).freeze
      MAX_TITLE_LENGTH = 160
      MAX_DESCRIPTION_LENGTH = 5_000
      MAX_UNIT_LENGTH = 50
      MAX_LOCATION_LENGTH = 500
      MAX_REJECTION_REASON_LENGTH = 1_000
      MAX_QUANTITY = BigDecimal("9999999999.99")

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"
      belongs_to :partner_profile,
                 class_name: "Decidim::Bih::PartnerProfile",
                 inverse_of: :contribution_needs
      belongs_to :author,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_author_id",
                 optional: true
      belongs_to :reviewer,
                 class_name: "Decidim::User",
                 foreign_key: "reviewed_by_id",
                 optional: true
      belongs_to :project,
                 class_name: "Decidim::Budgets::Project",
                 foreign_key: "decidim_budgets_project_id",
                 optional: true
      has_many :offers,
               class_name: "Decidim::Bih::ContributionOffer",
               dependent: :restrict_with_exception,
               inverse_of: :contribution_need

      before_validation :normalize_fields

      validates :need_type, presence: true, inclusion: { in: NEED_TYPES }
      validates :title, presence: true, length: { maximum: MAX_TITLE_LENGTH }
      validates :description, presence: true, length: { maximum: MAX_DESCRIPTION_LENGTH }
      validates :quantity,
                presence: true,
                numericality: { greater_than: 0, less_than_or_equal_to: MAX_QUANTITY }
      validates :unit, presence: true, length: { maximum: MAX_UNIT_LENGTH }
      validates :location, length: { maximum: MAX_LOCATION_LENGTH }, allow_blank: true
      validates :author, presence: true, on: :create
      validates :review_status, inclusion: { in: REVIEW_STATUSES }
      validates :fulfillment_status, inclusion: { in: FULFILLMENT_STATUSES }
      validates :rejection_reason, length: { maximum: MAX_REJECTION_REASON_LENGTH }, allow_blank: true
      validate :associations_belong_to_organization
      validate :partner_profile_is_verified, on: :create
      validate :author_is_volunteer_manager, on: :create
      validate :project_is_approved_and_donation_enabled, if: :project_link_validation_required?

      scope :pending_review, -> { where(review_status: "pending") }
      scope :approved, -> { where(review_status: "approved") }
      scope :approved_open, -> { approved.where(fulfillment_status: "open") }
      scope :fulfilled, -> { where(fulfillment_status: "fulfilled") }

      def pending_review?
        review_status == "pending"
      end

      def approved?
        review_status == "approved"
      end

      def rejected?
        review_status == "rejected"
      end

      def open?
        fulfillment_status == "open"
      end

      def fulfilled?
        fulfillment_status == "fulfilled"
      end

      def cancelled?
        fulfillment_status == "cancelled"
      end

      def managed_by?(user)
        return false if user.blank? || partner_profile.blank?

        membership = partner_profile.memberships.accepted.find_by(user:)
        membership&.volunteer_manager? || false
      end

      def confirmed_quantity
        offers.where(status: "confirmed").sum(:quantity)
      end

      # Proposals do not reserve capacity. The receiving partner reserves a
      # quantity by accepting it, under the need lock in ManageContributionOffer.
      def remaining_quantity(excluding: nil)
        reservations = offers.where(status: ContributionOffer::RESERVING_STATUSES)
        reservations = reservations.where.not(id: excluding.id) if excluding&.persisted?
        [quantity - reservations.sum(:quantity), 0].max
      end

      private

      def normalize_fields
        self.need_type = need_type.to_s.strip
        self.title = title.to_s.strip
        self.description = description.to_s.strip
        self.unit = unit.to_s.strip
        self.location = location.to_s.strip.presence
        self.review_status = review_status.to_s.presence || "pending"
        self.fulfillment_status = fulfillment_status.to_s.presence || "open"
        self.rejection_reason = rejection_reason.to_s.strip.presence
      end

      def associations_belong_to_organization
        return if organization.blank?

        validate_organization_of(:partner_profile, partner_profile)
        validate_organization_of(:author, author)
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

      def author_is_volunteer_manager
        return if author.blank? || partner_profile.blank? || managed_by?(author)

        errors.add(:author, :invalid)
      end

      def project_is_approved_and_donation_enabled
        return if project.blank? || organization.blank? || partner_profile.blank?

        linked = ProjectDonationLink.active.exists?(organization:, project:)
        submitted = PartnerProjectSubmission.approved.exists?(organization:, partner_profile:, project:)
        errors.add(:project, :invalid) unless linked && submitted
      end

      def project_link_validation_required?
        new_record? || will_save_change_to_decidim_budgets_project_id?
      end
    end
  end
end

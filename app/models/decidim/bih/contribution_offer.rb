# frozen_string_literal: true

module Decidim
  module Bih
    # A bounded, privacy-minimized offer against one approved non-cash need.
    # Confirmation is performed by the receiving partner; LFBN recognition is a
    # separate marker and is the only transition that can award citizen points.
    class ContributionOffer < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_contribution_offers"

      STATUSES = %w(offered accepted declined withdrawn delivered confirmed).freeze
      ACTIVE_STATUSES = %w(offered accepted delivered confirmed).freeze
      RESERVING_STATUSES = %w(accepted delivered confirmed).freeze
      MAX_DECLINE_REASON_LENGTH = 1_000

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"
      belongs_to :contribution_need,
                 class_name: "Decidim::Bih::ContributionNeed",
                 inverse_of: :offers
      belongs_to :contributor,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id",
                 optional: true
      belongs_to :partner_profile,
                 class_name: "Decidim::Bih::PartnerProfile",
                 optional: true,
                 inverse_of: :contribution_offers
      belongs_to :accepted_by,
                 class_name: "Decidim::User",
                 optional: true
      belongs_to :declined_by,
                 class_name: "Decidim::User",
                 optional: true
      belongs_to :confirmed_by,
                 class_name: "Decidim::User",
                 optional: true
      belongs_to :recognized_by,
                 class_name: "Decidim::User",
                 optional: true

      before_validation :normalize_fields

      validates :quantity, presence: true, numericality: { greater_than: 0 }
      validates :contributor, presence: true, on: :create
      validates :status, inclusion: { in: STATUSES }
      validates :decline_reason, length: { maximum: MAX_DECLINE_REASON_LENGTH }, allow_blank: true
      validate :associations_belong_to_organization
      validate :need_accepts_offers, on: :create
      validate :receiving_profile_is_publicly_eligible, on: :create
      validate :offering_profile_is_eligible, on: :create
      validate :contributor_may_represent_profile, on: :create
      validate :quantity_fits_remaining_need, on: :create

      scope :active, -> { where(status: ACTIVE_STATUSES) }
      scope :confirmed, -> { where(status: "confirmed") }
      scope :pending_recognition, -> { confirmed.where(recognized_at: nil) }
      scope :recognized, -> { confirmed.where.not(recognized_at: nil) }

      def offered?
        status == "offered"
      end

      def accepted?
        status == "accepted"
      end

      def declined?
        status == "declined"
      end

      def withdrawn?
        status == "withdrawn"
      end

      def delivered?
        status == "delivered"
      end

      def confirmed?
        status == "confirmed"
      end

      def recognized?
        recognized_at.present?
      end

      def personal?
        partner_profile.blank?
      end

      private

      def normalize_fields
        self.status = status.to_s.presence || "offered"
        self.decline_reason = decline_reason.to_s.strip.presence
      end

      def associations_belong_to_organization
        return if organization.blank?

        validate_organization_of(:contribution_need, contribution_need)
        validate_organization_of(:contributor, contributor)
        validate_organization_of(:partner_profile, partner_profile)
        [:accepted_by, :declined_by, :confirmed_by, :recognized_by].each do |association|
          validate_organization_of(association, public_send(association))
        end
      end

      def validate_organization_of(name, record)
        errors.add(name, :invalid) if record.present? && record.organization != organization
      end

      def need_accepts_offers
        return if contribution_need.blank?
        return if contribution_need.approved? && contribution_need.open?

        errors.add(:contribution_need, :invalid)
      end

      def receiving_profile_is_publicly_eligible
        return if contribution_need.blank? || organization.blank?

        eligible = PartnerProfile.publicly_visible.exists?(
          id: contribution_need.partner_profile_id,
          decidim_organization_id: organization.id
        )
        errors.add(:contribution_need, :invalid) unless eligible
      end

      def offering_profile_is_eligible
        return if partner_profile.blank? || organization.blank?

        eligible = PartnerProfile.volunteer_opportunity_eligible.exists?(
          id: partner_profile.id,
          decidim_organization_id: organization.id
        )
        errors.add(:partner_profile, :invalid) unless eligible
      end

      def contributor_may_represent_profile
        return if partner_profile.blank? || contributor.blank?

        membership = partner_profile.memberships.accepted.find_by(user: contributor)
        return if membership&.volunteer_manager?

        errors.add(:contributor, :invalid)
      end

      def quantity_fits_remaining_need
        return if contribution_need.blank? || quantity.blank?
        return if quantity <= contribution_need.remaining_quantity(excluding: self)

        errors.add(:quantity, :less_than_or_equal_to, count: contribution_need.remaining_quantity(excluding: self))
      end
    end
  end
end

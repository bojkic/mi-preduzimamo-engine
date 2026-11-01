# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Mutable operator-review record for organization wallet spending. It is
      # deliberately separate from the append-only ledger: pending/rejected rows
      # are workflow state, and only approval posts an immutable ledger entry.
      class OrganizationSpendingRequest < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_org_spending_requests"

        REQUEST_TYPES = %w(inter_org_support reward_sponsorship).freeze
        STATUSES = %w(pending approved rejected).freeze
        INTER_ORG_CATEGORIES = %w(
          collaboration
          shared_action
          emergency_support
          mentoring
          shared_resources
          other
        ).freeze
        REWARD_CATEGORIES = %w(
          voucher
          sponsored_inventory
          event_reward
          public_action_reward
          other
        ).freeze
        MAX_REWARD_TITLE_LENGTH = 160
        MAX_REWARD_DESCRIPTION_LENGTH = 1_500
        MAX_REJECTION_REASON_LENGTH = 1_000

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"
        belongs_to :source_partner_profile,
                   class_name: "Decidim::Bih::PartnerProfile"
        belongs_to :target_partner_profile,
                   class_name: "Decidim::Bih::PartnerProfile",
                   optional: true
        belongs_to :requested_by,
                   class_name: "Decidim::User",
                   optional: true
        belongs_to :decided_by,
                   class_name: "Decidim::User",
                   optional: true

        validates :request_type, presence: true, inclusion: { in: REQUEST_TYPES }
        validates :status, presence: true, inclusion: { in: STATUSES }
        validates :points, numericality: { only_integer: true, greater_than: 0 }
        validates :category, presence: true
        validates :reward_title, length: { maximum: MAX_REWARD_TITLE_LENGTH }, allow_blank: true
        validates :reward_description, length: { maximum: MAX_REWARD_DESCRIPTION_LENGTH }, allow_blank: true
        validates :reward_stock,
                  numericality: { only_integer: true, greater_than: 0 },
                  allow_nil: true
        validates :reward_cost,
                  numericality: { only_integer: true, greater_than: 0 },
                  allow_nil: true
        validates :rejection_reason, length: { maximum: MAX_REJECTION_REASON_LENGTH }, allow_blank: true
        validate :profiles_belong_to_organization
        validate :source_profile_is_eligible
        validate :target_profile_for_inter_org_support
        validate :reward_fields_for_sponsorship
        validate :category_allowed_for_request_type

        scope :pending, -> { where(status: "pending") }
        scope :approved, -> { where(status: "approved") }
        scope :rejected, -> { where(status: "rejected") }

        def pending?
          status == "pending"
        end

        def approved?
          status == "approved"
        end

        def inter_org_support?
          request_type == "inter_org_support"
        end

        def reward_sponsorship?
          request_type == "reward_sponsorship"
        end

        def category_label
          I18n.t(
            "decidim.bih.organizations.spending_categories.#{request_type}.#{category}",
            default: category.to_s.humanize
          )
        end

        private

        def profiles_belong_to_organization
          return if organization.blank?

          errors.add(:source_partner_profile, :invalid) if source_partner_profile.present? && source_partner_profile.organization != organization

          errors.add(:target_partner_profile, :invalid) if target_partner_profile.present? && target_partner_profile.organization != organization
        end

        def source_profile_is_eligible
          return if source_partner_profile.blank?

          errors.add(:source_partner_profile, :invalid) unless source_partner_profile.goodwill_eligible?
        end

        def target_profile_for_inter_org_support
          return unless inter_org_support?

          if target_partner_profile.blank?
            errors.add(:target_partner_profile, :blank)
            return
          end

          errors.add(:target_partner_profile, :invalid) unless target_partner_profile.goodwill_eligible?
          errors.add(:target_partner_profile, :invalid) if target_partner_profile == source_partner_profile
        end

        def reward_fields_for_sponsorship
          return unless reward_sponsorship?

          errors.add(:reward_title, :blank) if reward_title.blank?
          errors.add(:reward_stock, :blank) if reward_stock.blank?
          errors.add(:reward_cost, :blank) if reward_cost.blank?
        end

        def category_allowed_for_request_type
          allowed = if inter_org_support?
                      INTER_ORG_CATEGORIES
                    elsif reward_sponsorship?
                      REWARD_CATEGORIES
                    else
                      []
                    end
          errors.add(:category, :inclusion) unless allowed.include?(category)
        end
      end
    end
  end
end

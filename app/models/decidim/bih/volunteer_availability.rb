# frozen_string_literal: true

module Decidim
  module Bih
    # A signed-in citizen's general volunteer interest/availability.
    # One record per organization/user; first registration earns a one-time
    # goodwill award through RegisterVolunteerAvailability.
    class VolunteerAvailability < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_volunteer_availabilities"

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id"

      belongs_to :local_area,
                 class_name: "Decidim::Bih::LocalArea",
                 optional: true

      before_validation :normalize_structured_fields

      validates :user, uniqueness: { scope: :decidim_organization_id }
      validates :area_scope, inclusion: { in: Decidim::Bih::VolunteeringTaxonomy::AREA_SCOPES }
      # Bound the free-text fields: they carry PII under a 3-year retention window.
      validates :availability, length: { maximum: 2_000 }, allow_blank: true
      validates :interests, length: { maximum: 2_000 }, allow_blank: true
      validate :local_area_matches_scope
      validate :simple_schedule_keys_are_valid

      def citywide?
        area_scope == "city"
      end

      def area_label
        return Decidim::Bih::VolunteeringTaxonomy.label(:area_scopes, "city") if citywide?

        local_area&.translated_name ||
          Decidim::Bih::VolunteeringTaxonomy.label(:area_scopes, area_scope)
      end

      def interest_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:interests, interest_keys)
      end

      def skill_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:skills, skill_keys)
      end

      def capability_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:capabilities, capability_keys)
      end

      def day_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:weekdays, day_keys)
      end

      def month_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:months, month_keys)
      end

      def time_slot_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:time_slots, time_slot_keys)
      end

      def schedule_labels
        [
          Decidim::Bih::VolunteeringTaxonomy.summary_for(:weekdays, day_keys, all_key: :all_days),
          Decidim::Bih::VolunteeringTaxonomy.summary_for(:months, month_keys, all_key: :all_months),
          Decidim::Bih::VolunteeringTaxonomy.summary_for(:time_slots, time_slot_keys, all_key: :all_time_slots)
        ]
      end

      private

      def normalize_structured_fields
        self.area_scope = area_scope.to_s.presence || "city"
        self.local_area = nil if citywide?
        self.availability_windows = []
        self.day_keys = normalized_keys_or_default(day_keys, :weekdays)
        self.month_keys = normalized_keys_or_default(month_keys, :months)
        self.time_slot_keys = normalized_keys_or_default(time_slot_keys, :time_slots)
        self.interest_keys = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(
          interest_keys,
          Decidim::Bih::VolunteeringTaxonomy::INTERESTS
        )
        self.skill_keys = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(
          skill_keys,
          Decidim::Bih::VolunteeringTaxonomy::SKILLS
        )
        self.capability_keys = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(
          capability_keys,
          Decidim::Bih::VolunteeringTaxonomy::CAPABILITIES
        )
      end

      def normalized_keys_or_default(values, group)
        keys = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(
          values,
          Decidim::Bih::VolunteeringTaxonomy.default_keys(group)
        )
        keys.presence || Decidim::Bih::VolunteeringTaxonomy.default_keys(group)
      end

      def local_area_matches_scope
        if citywide?
          errors.add(:local_area, :present) if local_area_id.present?
          return
        end

        if local_area.blank?
          errors.add(:local_area, :blank)
          return
        end

        errors.add(:local_area, :invalid) unless local_area.decidim_organization_id == decidim_organization_id
        errors.add(:local_area, :invalid) unless local_area.kind == area_scope
      end

      def simple_schedule_keys_are_valid
        errors.add(:day_keys, :blank) if day_keys.blank?
        errors.add(:month_keys, :blank) if month_keys.blank?
        errors.add(:time_slot_keys, :blank) if time_slot_keys.blank?
      end
    end
  end
end

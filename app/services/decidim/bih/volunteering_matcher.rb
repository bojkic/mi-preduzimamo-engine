# frozen_string_literal: true

module Decidim
  module Bih
    # Privacy-preserving matching between a citizen's structured availability and
    # published volunteering opportunities. Public pages use per-viewer scores;
    # admin pages only receive aggregate counts.
    class VolunteeringMatcher
      LEGACY_CATEGORY_ALIASES = {
        "admin_logistics" => "neighborhood_infrastructure"
      }.freeze

      LEGACY_INTEREST_CATEGORY_ALIASES = {
        "people_support" => %w(community_care humanitarian),
        "events" => %w(events_culture sports_recreation),
        "neighborhood_help" => %w(neighborhood_infrastructure)
      }.freeze

      def self.scores_by_opportunity(opportunities, availability)
        Array(opportunities).index_with { |opportunity| new(opportunity, availability).score }
      end

      def self.match_count(opportunity, availabilities:)
        Array(availabilities).count { |availability| new(opportunity, availability).match? }
      end

      def initialize(opportunity, availability)
        @opportunity = opportunity
        @availability = availability
      end

      def match?
        score.positive?
      end

      def score
        return 0 if opportunity.blank? || availability.blank?

        area = area_score
        return 0 if explicit_area_mismatch?(area)

        [
          area,
          time_score,
          interest_score,
          skill_score,
          capability_score
        ].sum
      end

      private

      attr_reader :opportunity, :availability

      def area_score
        return 20 if availability.citywide?
        return 0 if availability.local_area.blank? || opportunity.komsiluk.blank?

        case availability.area_scope
        when "komsiluk"
          opportunity.komsiluk_id == availability.local_area_id ? 40 : 0
        when "mz"
          komsiluk_matches_mz? ? 35 : 0
        else
          0
        end
      end

      def explicit_area_mismatch?(area)
        area.zero? && !availability.citywide? && availability.local_area.present? && opportunity.komsiluk.present?
      end

      def komsiluk_matches_mz?
        mz = availability.local_area
        komsiluk = opportunity.komsiluk
        return false if mz.blank? || komsiluk.blank?

        komsiluk.primary_mz_slug == mz.slug ||
          Array(komsiluk.overlapping_mz_slugs).include?(mz.slug) ||
          komsiluk.parent_id == mz.id
      end

      def time_score
        return 0 if availability.blank?

        day_overlap = schedule_keys(:weekdays, opportunity_day_keys, availability.day_keys).any?
        month_overlap = schedule_keys(:months, opportunity_month_keys, availability.month_keys).any?
        slot_overlap = schedule_keys(:time_slots, opportunity_time_slot_keys, availability.time_slot_keys).any?
        day_overlap && month_overlap && slot_overlap ? 30 : 0
      end

      def opportunity_day_keys
        return [weekday_key(opportunity.starts_at)] if opportunity.starts_at.present?

        Array(opportunity.day_keys)
      end

      def opportunity_month_keys
        return [Decidim::Bih::VolunteeringTaxonomy::MONTHS[opportunity.starts_at.month - 1]] if opportunity.starts_at.present?

        Array(opportunity.month_keys)
      end

      def opportunity_time_slot_keys
        return [time_slot_key(opportunity.starts_at)] if opportunity.starts_at.present?

        Array(opportunity.time_slot_keys)
      end

      def schedule_keys(group, opportunity_keys, availability_keys)
        defaults = Decidim::Bih::VolunteeringTaxonomy.default_keys(group)
        opportunity = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(opportunity_keys, defaults).presence || defaults
        availability = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(availability_keys, defaults).presence || defaults
        opportunity & availability
      end

      def weekday_key(time)
        Decidim::Bih::VolunteeringTaxonomy::WEEKDAYS[time.wday.zero? ? 6 : time.wday - 1]
      end

      def time_slot_key(time)
        time.hour < 13 ? "day" : "afternoon"
      end

      def interest_score
        category = normalized_category(opportunity.category)
        keys = Array(availability.interest_keys).map(&:to_s)
        return 0 if category.blank? || keys.blank?
        return 20 if keys.include?(category)
        return 20 if keys.any? { |key| LEGACY_INTEREST_CATEGORY_ALIASES.fetch(key, []).include?(category) }

        0
      end

      def normalized_category(category)
        category = category.to_s
        LEGACY_CATEGORY_ALIASES.fetch(category, category)
      end

      def skill_score
        Array(opportunity.skill_keys).intersect?(Array(availability.skill_keys)) ? 15 : 0
      end

      def capability_score
        Array(opportunity.capability_keys).intersect?(Array(availability.capability_keys)) ? 10 : 0
      end
    end
  end
end

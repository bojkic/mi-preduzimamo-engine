# frozen_string_literal: true

module Decidim
  module Bih
    # Stable keys used by the public volunteering forms, matching and admin
    # filters. Labels live in i18n so stored values remain language-neutral.
    module VolunteeringTaxonomy
      AREA_SCOPES = %w(city mz komsiluk).freeze
      WEEKDAYS = %w(monday tuesday wednesday thursday friday saturday sunday).freeze
      MONTHS = %w(
        january
        february
        march
        april
        may
        june
        july
        august
        september
        october
        november
        december
      ).freeze
      TIME_SLOTS = %w(day afternoon).freeze

      CATEGORIES = %w(
        environment
        community_care
        events_culture
        education_youth
        sports_recreation
        humanitarian
        neighborhood_infrastructure
        digital_media
      ).freeze

      LEGACY_CATEGORIES = %w(admin_logistics other).freeze
      INTERESTS = CATEGORIES

      SKILLS = %w(
        field_work
        organization
        transport
        communication
        digital_support
        mentoring
      ).freeze

      CAPABILITIES = %w(
        has_car
        has_tools
        outdoor_work
      ).freeze

      OPTION_GROUPS = {
        area_scopes: AREA_SCOPES,
        weekdays: WEEKDAYS,
        months: MONTHS,
        time_slots: TIME_SLOTS,
        categories: CATEGORIES,
        interests: INTERESTS,
        skills: SKILLS,
        capabilities: CAPABILITIES
      }.freeze

      module_function

      def allowed_keys(group)
        OPTION_GROUPS.fetch(group).to_set
      end

      def sanitize_keys(values, allowed)
        allowed_set = allowed.is_a?(Set) ? allowed : allowed.to_set
        Array(values).flatten.filter_map do |value|
          key = value.to_s.strip
          key if allowed_set.include?(key)
        end.uniq
      end

      def label(group, key, locale: I18n.locale)
        group = :categories if group.to_sym == :interests && CATEGORIES.include?(key.to_s)

        I18n.t(
          "decidim.bih.volunteering_taxonomy.#{group}.#{key}",
          locale:,
          default: key.to_s.tr("_", " ").capitalize
        )
      end

      def option_pairs(group, locale: I18n.locale)
        OPTION_GROUPS.fetch(group).map { |key| [label(group, key, locale:), key] }
      end

      def labels_for(group, keys, locale: I18n.locale)
        sanitize_keys(keys, OPTION_GROUPS.fetch(group)).map { |key| label(group, key, locale:) }
      end

      def summary_for(group, keys, all_key:, locale: I18n.locale)
        sanitized = sanitize_keys(keys, OPTION_GROUPS.fetch(group))
        return I18n.t("decidim.bih.volunteering_taxonomy.summaries.#{all_key}", locale:) if sanitized.blank? || sanitized == OPTION_GROUPS.fetch(group)

        sanitized.map { |key| label(group, key, locale:) }.join(", ")
      end

      def default_keys(group)
        OPTION_GROUPS.fetch(group)
      end

      def category_label(key, locale: I18n.locale)
        key = key.to_s
        return "" if key.blank?
        return label(:categories, key, locale:) if CATEGORIES.include?(key) || LEGACY_CATEGORIES.include?(key)

        key
      end
    end
  end
end

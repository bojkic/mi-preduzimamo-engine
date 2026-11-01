# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Validate the complete request before touching the store. Missing sections
      # and keys are untouched; an explicitly blank value clears one override.
      class SettingsUpdate
        class Invalid < StandardError; end
        MAX_POINTS = 100_000
        MAX_CAP = 10_000

        def initialize(organization:, sections:, rationale:)
          @organization = organization
          @sections = sections.stringify_keys
          @rationale = rationale.to_s.strip
        end

        def call!
          updates = normalized_updates
          @organization.with_lock do
            changed = updates.any? do |namespace, values|
              stored = Setting.where(organization: @organization, namespace:).pluck(:key, :value).to_h
              values.any? { |key, value| value.nil? ? stored.key?(key) : stored[key] != value }
            end
            raise Invalid, "approval_rationale_required" if changed && @rationale.blank?

            updates.each do |namespace, values|
              values.each { |key, value| Setting.put(@organization, namespace, key, value) }
            end
            if section_keys("schedule").include?("report")
              report_points = EarningRules.new(organization: @organization).points_for(:report)
              raise Invalid, "invalid_values" if report_points.positive? && report_points < ReportEntitlement::DUPLICATE_POINTS
            end
            validate_registration!
            # Audit is part of the same transaction, including on no-op saves.
            yield({ schedule_keys: section_keys("schedule"), cap_keys: section_keys("caps"),
                    monthly_cap_keys: section_keys("monthly_caps"),
                    season_present: @sections.dig("settings", "season_started_at").present?,
                    approval_rationale: @rationale.presence }.compact) if block_given?
          end
          true
        end

        private

        def normalized_updates
          raise Invalid, "invalid_values" unless (@sections.keys - %w(schedule caps monthly_caps settings)).empty?

          result = {}
          { "schedule" => [EarningRules::SCHEDULE_NAMESPACE, EarningRules::DEFAULT_SCHEDULE.keys, MAX_POINTS],
            "caps" => [EarningRules::CAPS_NAMESPACE, EarningRules::DEFAULT_DAILY_CAPS.keys, MAX_CAP],
            "monthly_caps" => [EarningRules::MONTHLY_CAPS_NAMESPACE, EarningRules::DEFAULT_MONTHLY_CAPS.keys, MAX_CAP] }.each do |section, (namespace, keys, max)|
            next unless @sections.key?(section)

            values = checked_section(section, keys.map(&:to_s))
            result[namespace] = values.transform_values { |value| integer_or_clear(value, max) }
          end
          if @sections.key?("settings")
            values = checked_section("settings", %w(season_started_at))
            if values.key?("season_started_at")
              raw = scalar(values.fetch("season_started_at"))
              date = raw.empty? ? nil : Date.iso8601(raw).iso8601
              raise Invalid, "invalid_values" if date && date != raw

              result[EarningRules::SEASON_NAMESPACE] = { EarningRules::SEASON_KEY => date }
            end
          end
          result
        rescue Date::Error, ArgumentError, TypeError
          raise Invalid, "invalid_values"
        end

        def checked_section(name, keys)
          values = @sections.fetch(name)
          raise Invalid, "invalid_values" unless values.is_a?(Hash)

          values = values.stringify_keys
          raise Invalid, "invalid_values" unless (values.keys - keys).empty?

          @sections[name] = values
        end

        def section_keys(name)
          @sections.fetch(name, {}).keys
        end

        def scalar(value)
          raise Invalid, "invalid_values" unless value.nil? || value.is_a?(String) || value.is_a?(Integer)

          value.to_s.strip
        end

        def integer_or_clear(value, maximum)
          raw = scalar(value)
          return nil if raw.empty?

          raise Invalid, "invalid_values" unless raw.match?(/\A\d+\z/) && raw.size <= 6

          number = Integer(raw, 10)
          raise Invalid, "invalid_values" unless number.between?(0, maximum)

          number
        end

        def validate_registration!
          return if (section_keys("schedule") & %w(verification komsiluk_selected)).empty?

          rules = EarningRules.new(organization: @organization)
          total = rules.points_for(:verification) + rules.points_for(:komsiluk_selected)
          raise Invalid, "registration_total" unless total == 20

          invitation = Reward.where(organization: @organization, key: "pozivnica_lansiranje", active: true).first
          return unless invitation && !invitation.expired? && invitation.auto_issue_at_threshold?

          raise Invalid, "registration_total" unless invitation.cost == total
        end
      end
    end
  end
end

# frozen_string_literal: true

require "date"
require_relative "contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Copy-only projection of a typed public catalog result. Never consult
        # a citizen's text, inferred home, member board or retained old answer.
        module PublicCatalogEmptyAnswer
          TOPICS = %w(volunteer participation).freeze
          UNMAPPED = %w(mz_to_opportunity_crosswalk_not_reviewed participation_geography_not_reviewed).freeze

          module_function

          def call(result:, topic:, locale:)
            return unless eligible?(result, topic)

            area_text = selected_areas(result.coverage, locale:)
            time_text = requested_time(result.validity, locale:)
            return if area_text.nil? || time_text.nil?

            lead = result.warnings.intersect?(UNMAPPED) ? "catalog_empty_scope_unavailable" : "catalog_empty_#{topic}"
            [translate(lead, locale:), area_text, time_text, translate("catalog_empty_limit", locale:)].reject(&:empty?).join("\n")
          rescue ArgumentError, KeyError
            nil
          end

          def eligible?(result, topic)
            result.is_a?(Contracts::ReadResult) && result.status == "empty" && result.facts.empty? && TOPICS.include?(topic) &&
              result.source.is_a?(Hash) && result.source["id"] == "platform:#{topic}" &&
              result.coverage.is_a?(Hash) && result.coverage.values_at("access", "complete_inventory") == ["public", false]
          end

          def selected_areas(coverage, locale:)
            areas = selected_area_rows(coverage)
            return unless areas
            return "" if areas.empty?

            names = areas.map { |area| translate("catalog_area_#{area.fetch("kind")}", locale:, name: area_name(area)) }
            translate("catalog_requested_areas", locale:, areas: names.join("; "))
          end

          def area_name(area)
            # Registry names may already contain their kind. Remove only the
            # matching display prefix; never change the typed area identity.
            label = area.fetch("label")
            prefix = area.fetch("kind") == "mz" ? /\A(?:MZ|МЗ)\s+(?=\S)/i : /\A(?:Komšiluk|Komsiluk|Комшилук|Neighborhood)\s+(?=\S)/i
            label.sub(prefix, "")
          end

          def selected_area_rows(coverage)
            areas = coverage["requested_areas"]
            slugs = coverage["requested_area_slugs"]
            return unless areas.is_a?(Array) && areas.length <= 8 && slugs.is_a?(Array)
            return unless areas.all? { |area| valid_area?(area) } && areas.map { |area| area["slug"] } == slugs && slugs.uniq == slugs

            areas
          end

          def valid_area?(area)
            return false unless area.is_a?(Hash) && %w(mz komsiluk).include?(area["kind"])

            slug, label = area.values_at("slug", "label")
            slug.is_a?(String) && slug.match?(/\A[a-z0-9][a-z0-9_-]{0,99}\z/) &&
              label.is_a?(String) && label.length.between?(1, 160) && label.match?(/\A[\p{L}\p{M}\d .,'’()\-]+\z/u)
          end

          def requested_time(validity, locale:)
            return unless validity.is_a?(Hash) && validity["timezone"] == "Europe/Sarajevo"

            if validity["requested_dates"]
              return range_text(validity, locale:) unless validity["requested_date"]

              return
            end
            date = validity["requested_date"]
            return "" if date.nil?

            translate("catalog_requested_date", locale:, date: date_value(date).iso8601, timezone: validity.fetch("timezone"))
          end

          def range_text(validity, locale:)
            dates = validity.fetch("requested_dates")
            return unless dates.is_a?(Hash) && %w(weekend next_seven_days).include?(validity["range_kind"])

            from = date_value(dates.fetch("from"))
            through = date_value(dates.fetch("through"))
            days = validity["range_kind"] == "weekend" ? 1 : 6
            return unless through - from == days
            return if validity["range_kind"] == "weekend" && (!from.saturday? || !through.sunday?)

            translate("catalog_requested_range", locale:, from: from.iso8601, through: through.iso8601, timezone: validity.fetch("timezone"))
          end

          def date_value(value)
            raise ArgumentError, "Expected ISO calendar date" unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

            Date.iso8601(value)
          end

          def translate(key, locale:, **values)
            I18n.t("decidim.bih.dialogue.#{key}", locale:, raise: true, **values)
          end

          private_class_method :eligible?, :selected_areas, :area_name, :selected_area_rows, :valid_area?, :requested_time, :range_text, :date_value, :translate
        end
      end
    end
  end
end

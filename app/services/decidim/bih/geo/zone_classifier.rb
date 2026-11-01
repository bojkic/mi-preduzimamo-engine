# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Splits komšiluci into the race's two leagues by AREA OVERLAP with the
      # Bijeljina settlement frame: a komšiluk whose majority of area falls inside
      # the frame is "grad", everything else is "selo".
      #
      # The centroid is deliberately NOT used — an elongated komšiluk on the city
      # edge can have its centroid on the wrong side of the boundary.
      #
      # The frame is DATA, not a path in code: it lives in Decidim::Bih::Setting
      # (namespace "geo", key "city_frame") and is imported by
      # rake decidim_bih:geo:import_city_frame.
      #
      # The result is written to LocalArea#zona ONCE and then locked. The race
      # must never move a komšiluk between leagues mid-competition.
      class ZoneClassifier
        GRAD = "grad"
        SELO = "selo"
        # Below/above this share of area the league is obvious; inside this band
        # a human confirms, because the split decides who competes for 3.000 KM.
        BORDERLINE_RANGE = (0.40..0.60)
        FRAME_NAMESPACE = "geo"
        FRAME_KEY = "city_frame"
        LOCK_NAMESPACE = "race"
        LOCK_KEY = "zone_locked_at"

        class MissingCityFrameError < StandardError; end

        class ZonesLockedError < StandardError; end

        Result = Struct.new(:slug, :name, :ratio, :zona, keyword_init: true) do
          def borderline?
            BORDERLINE_RANGE.cover?(ratio)
          end
        end

        def initialize(organization)
          @organization = organization
        end

        def city_frame
          raw = Decidim::Bih::Setting.namespace_for(organization, FRAME_NAMESPACE)[FRAME_KEY]
          raw.is_a?(String) ? JSON.parse(raw) : raw
        end

        def locked?
          Decidim::Bih::Setting.namespace_for(organization, LOCK_NAMESPACE)[LOCK_KEY].present?
        end

        # Returns the ISO8601 STRING that was stored, not a Time. jsonb round-trips
        # a Time as a String regardless of what we hand it, so returning a Time
        # here would misdescribe what #locked? and every other reader actually
        # get back from Decidim::Bih::Setting.
        def lock!
          locked_at = Time.current.utc.iso8601
          Decidim::Bih::Setting.put(organization, LOCK_NAMESPACE, LOCK_KEY, locked_at)
          locked_at
        end

        # Computes the split WITHOUT writing. Sorted by share of area descending
        # so the report reads city-first. A komšiluk with no boundary yields
        # ratio 0.0 → selo; it is reported, never silently dropped.
        def classify
          frame = city_frame
          raise MissingCityFrameError, "No city frame stored for organization #{organization.id}" if frame.blank?

          index = PolygonArea::ClipIndex.new(frame)

          results = komsiluci.map do |area|
            ratio = area.boundary.present? ? PolygonArea.covered_ratio(area.boundary, index) : 0.0
            Result.new(slug: area.slug, name: area.translated_name, ratio:, zona: ratio > 0.5 ? GRAD : SELO)
          end
          results.sort_by { |result| -result.ratio }
        end

        def apply!(force: false)
          raise ZonesLockedError, "Zones are locked; pass force: true to override" if locked? && !force

          results = classify
          by_slug = results.index_by(&:slug)

          Decidim::Bih::LocalArea.transaction do
            komsiluci.each do |area|
              result = by_slug[area.slug]
              next unless result

              area.update!(
                zona: result.zona,
                metadata: (area.metadata || {}).merge("zona_ratio" => result.ratio.round(6))
              )
            end
          end

          results
        end

        private

        attr_reader :organization

        def komsiluci
          Decidim::Bih::LocalArea.komsiluci.where(organization:).order(:slug)
        end
      end
    end
  end
end

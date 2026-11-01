# frozen_string_literal: true

module Decidim
  module Bih
    # Likely-duplicate detection for the WEB "Bice riseno" intake. Given a point
    # (lat/lng) and an optional category, it surfaces recent, still-open reports
    # within a small radius of that point — so a repeat report can be turned into
    # corroboration of the existing one instead of fresh triage noise for the city.
    #
    # Org-scoped by construction: it never looks at another organization's reports.
    # Used ONLY from the controller intake flow; the Viber/bot path is untouched.
    #
    #   Decidim::Bih::DuplicateFinder.new.call(
    #     organization: org, latitude: 44.756, longitude: 19.216, category: "putevi"
    #   ) # => the best matching Decidim::Bih::Report, or nil
    #
    class DuplicateFinder
      # How close two reports must be to be considered the same issue (~100 m).
      DEFAULT_RADIUS_METERS = 100.0
      # How recent a report must be to still be an active duplicate candidate.
      DEFAULT_WINDOW_DAYS = 30
      # Cap on candidates pulled back for the Ruby refine — a small bounding box
      # over a 30-day window is tiny, but bound it defensively.
      CANDIDATE_LIMIT = 50

      EARTH_RADIUS_METERS = 6_371_000.0

      def initialize(radius_meters: DEFAULT_RADIUS_METERS, window_days: DEFAULT_WINDOW_DAYS)
        @radius_meters = radius_meters.to_f
        @window_days = window_days.to_i
      end

      # The single best matching report, or nil when there is none. The best
      # match is the nearest candidate, preferring one in the same category.
      def call(organization:, latitude:, longitude:, category: nil)
        matches(
          organization: organization,
          latitude: latitude,
          longitude: longitude,
          category: category
        ).first
      end

      # The ordered list of likely-duplicate reports (best first). Same-category
      # candidates rank ahead of others; within each group, nearest wins.
      def matches(organization:, latitude:, longitude:, category: nil)
        lat = to_coordinate(latitude)
        lng = to_coordinate(longitude)
        return [] if organization.nil? || lat.nil? || lng.nil?

        candidates = bounding_box_scope(organization, lat, lng)
        ranked = candidates.filter_map do |report|
          distance = haversine_meters(lat, lng, report.latitude, report.longitude)
          next if distance.nil? || distance > @radius_meters

          [report, distance]
        end

        ranked
          .sort_by { |report, distance| [same_category_rank(report, category), distance] }
          .map(&:first)
      end

      private

      # SQL bounding-box prefilter: cheap lat/lng range scan that the Ruby
      # Haversine refine then trims to a true circular radius. The box is sized
      # from the radius in metres, widening the longitude band by the latitude's
      # cosine so it stays a real geographic box away from the equator.
      def bounding_box_scope(organization, lat, lng)
        # 111_000 m/degree is below the true min meters-per-degree (~111,132 at
        # 45°N), so the box is a strict SUPERSET of the true circle on both axes —
        # the Haversine refine then trims to the exact radius. (Using the wider
        # equatorial 111,320 could clip a candidate by < 1 m at the box edge.)
        meters_per_degree = 111_000.0
        lat_delta = @radius_meters / meters_per_degree
        cos_lat = Math.cos(lat * Math::PI / 180.0)
        lng_delta = cos_lat.abs < 1e-9 ? 180.0 : @radius_meters / (meters_per_degree * cos_lat.abs)

        Decidim::Bih::Report
          .publicly_visible
          .where(decidim_organization_id: organization.id)
          .where.not(status: Decidim::Bih::Report::TERMINAL_STATUSES)
          .where(created_at: @window_days.days.ago..)
          .where.not(latitude: nil).where.not(longitude: nil)
          .where(latitude: (lat - lat_delta)..(lat + lat_delta))
          .where(longitude: (lng - lng_delta)..(lng + lng_delta))
          .order(created_at: :desc, id: :desc)
          .limit(CANDIDATE_LIMIT)
      end

      # 0 when the report shares the queried category (and a category was given),
      # 1 otherwise — used as the primary sort key so same-category wins.
      def same_category_rank(report, category)
        return 1 if category.blank?

        report.category.to_s == category.to_s ? 0 : 1
      end

      def haversine_meters(lat1, lng1, lat2, lng2)
        return nil if lat2.nil? || lng2.nil?

        d_lat = (lat2 - lat1) * Math::PI / 180.0
        d_lng = (lng2 - lng1) * Math::PI / 180.0
        rad1 = lat1 * Math::PI / 180.0
        rad2 = lat2 * Math::PI / 180.0

        a = (Math.sin(d_lat / 2)**2) +
            (Math.cos(rad1) * Math.cos(rad2) * (Math.sin(d_lng / 2)**2))
        c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
        EARTH_RADIUS_METERS * c
      end

      def to_coordinate(value)
        return nil if value.nil? || (value.respond_to?(:blank?) && value.blank?)

        coord = Float(value)
        coord.finite? ? coord : nil
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end

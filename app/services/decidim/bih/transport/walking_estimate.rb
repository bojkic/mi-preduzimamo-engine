# frozen_string_literal: true

module Decidim
  module Bih
    module Transport
      # Timetable clocks are exact source cells; pedestrian durations are policy
      # estimates over map-derived straight-line coordinates.
      module WalkingEstimate
        EARTH_RADIUS_METERS = 6_371_000
        METERS_PER_SECOND = 1.2
        CIRCUITY = 1.3
        BOARDING_MARGIN_SECONDS = 60
        RANGE_VERSION = "walking_policy_v1"
        # Scenario bounds for unverified paths and pace, not a confidence interval.
        LOW_SECONDS_FACTOR = 0.75
        HIGH_SECONDS_FACTOR = 1.75

        module_function

        def distance_meters(a, b)
          lat1, lon1 = coordinates(a)
          lat2, lon2 = coordinates(b)
          phi1 = lat1 * Math::PI / 180
          phi2 = lat2 * Math::PI / 180
          dphi = (lat2 - lat1) * Math::PI / 180
          dlambda = (lon2 - lon1) * Math::PI / 180
          arc = Math.sin(dphi / 2)**2 + Math.cos(phi1) * Math.cos(phi2) * Math.sin(dlambda / 2)**2
          (2 * EARTH_RADIUS_METERS * Math.atan2(Math.sqrt(arc), Math.sqrt(1 - arc))).round
        end

        def seconds(distance_meters)
          ((distance_meters * CIRCUITY) / METERS_PER_SECOND).ceil
        end

        def range_for_seconds(nominal_seconds)
          value = Integer(nominal_seconds)
          raise ArgumentError, "negative walking estimate" if value.negative?

          { "version" => RANGE_VERSION, "low" => (value * LOW_SECONDS_FACTOR).floor,
            "high" => (value * HIGH_SECONDS_FACTOR).ceil }
        end

        def coordinates(point)
          value = point.transform_keys(&:to_sym)
          [Float(value.fetch(:latitude)), Float(value.fetch(:longitude))]
        end
      end
    end
  end
end

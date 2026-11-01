# frozen_string_literal: true

module Decidim
  module Bih
    module Transport
      # A public stop grid. Exact Haversine refinement makes cell edges safe;
      # no citizen point is retained by this object or its keys.
      class NearbyStops
        CELL_DEGREES = 0.002

        def initialize(stops)
          @cells = Hash.new { |hash, key| hash[key] = [] }
          Array(stops).each do |stop|
            next unless stop[:latitude] && stop[:longitude]

            @cells[cell(stop[:latitude], stop[:longitude])] << stop
          end
          @cells.each_value(&:freeze)
          @cells.freeze
        end

        def within(point, radius_meters: 200)
          latitude, longitude = WalkingEstimate.coordinates(point)
          return [] unless radius_meters.is_a?(Numeric) && radius_meters.between?(0, 3_000)

          lat_delta = radius_meters / 110_574.0
          lon_delta = radius_meters / (111_320.0 * Math.cos(latitude * Math::PI / 180).abs.clamp(0.01, 1))
          x0, y0 = cell(latitude - lat_delta, longitude - lon_delta)
          x1, y1 = cell(latitude + lat_delta, longitude + lon_delta)
          (x0..x1).flat_map do |x|
            (y0..y1).flat_map { |y| @cells.fetch([x, y], []) }
          end.filter_map do |stop|
            distance = WalkingEstimate.distance_meters(point, stop)
            [stop, distance] if distance <= radius_meters
          end.sort_by { |stop, distance| [distance, stop.fetch(:id)] }
        end

        private

        def cell(latitude, longitude)
          [(latitude.to_f / CELL_DEGREES).floor, (longitude.to_f / CELL_DEGREES).floor]
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Public projection of an operationally exact report location. Approximate
    # points are deterministic so markers and cache keys remain stable.
    class ReportPublicLocation
      GRID_DEGREES = 0.002

      def initialize(latitude:, longitude:, address:, exact: false)
        @latitude = latitude
        @longitude = longitude
        @address = address
        @exact = exact
      end

      def latitude
        coordinate(@latitude)
      end

      def longitude
        coordinate(@longitude)
      end

      def address
        @address if @exact
      end

      private

      def coordinate(value)
        return if value.nil?
        return value.to_f if @exact

        ((value.to_f / GRID_DEGREES).round * GRID_DEGREES).round(6)
      end
    end
  end
end

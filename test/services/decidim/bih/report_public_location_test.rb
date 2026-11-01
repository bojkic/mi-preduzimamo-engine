# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/report_public_location"

module Decidim
  module Bih
    class ReportPublicLocationTest < Minitest::Test
      def test_approximate_is_default_and_hides_address
        location = ReportPublicLocation.new(
          latitude: 44.75673,
          longitude: 19.21691,
          address: "Exact address 1"
        )

        assert_equal 44.756, location.latitude
        assert_equal 19.216, location.longitude
        assert_nil location.address
      end

      def test_explicit_exact_choice_preserves_coordinates_and_address
        location = ReportPublicLocation.new(
          latitude: 44.75673,
          longitude: 19.21691,
          address: "Exact address 1",
          exact: true
        )

        assert_equal 44.75673, location.latitude
        assert_equal 19.21691, location.longitude
        assert_equal "Exact address 1", location.address
      end

      def test_missing_coordinates_remain_missing
        location = ReportPublicLocation.new(latitude: nil, longitude: nil, address: nil)

        assert_nil location.latitude
        assert_nil location.longitude
      end
    end
  end
end

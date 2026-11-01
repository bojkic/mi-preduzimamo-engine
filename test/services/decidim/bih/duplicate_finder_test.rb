# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/numeric/time"
require_relative "../../../../app/services/decidim/bih/duplicate_finder"

module Decidim
  module Bih
    class DuplicateFinderTest < Minitest::Test
      OrgStub = Struct.new(:id, keyword_init: true)
      ReportStub = Struct.new(:latitude, :longitude, :category, keyword_init: true)

      class PureDuplicateFinder < DuplicateFinder
        attr_reader :scope_called

        def initialize(candidates:, **)
          super(**)
          @candidates = candidates
          @scope_called = false
        end

        def bounding_box_scope(*)
          @scope_called = true
          @candidates
        end
      end

      def test_missing_organization_short_circuits_without_querying_candidates
        finder = finder_with([])

        assert_equal [], finder.matches(organization: nil, latitude: 44.756, longitude: 19.216)
        assert_equal false, finder.scope_called
      end

      def test_blank_non_numeric_and_non_finite_coordinates_short_circuit
        ["", "abc", Float::NAN].each do |bad_latitude|
          finder = finder_with([])

          assert_equal [], finder.matches(organization: organization, latitude: bad_latitude, longitude: 19.216)
          assert_equal false, finder.scope_called
        end
      end

      def test_candidates_with_missing_coordinates_or_outside_radius_are_ignored
        inside = report(latitude: 44.7562, longitude: 19.216, category: "putevi")
        missing_latitude = report(latitude: nil, longitude: 19.216, category: "putevi")
        missing_longitude = report(latitude: 44.756, longitude: nil, category: "putevi")
        outside = report(latitude: 44.766, longitude: 19.216, category: "putevi")

        matches = finder_with([missing_latitude, inside, missing_longitude, outside])
                  .matches(organization:, latitude: 44.756, longitude: 19.216, category: "putevi")

        assert_equal [inside], matches
      end

      def test_same_category_candidate_ranks_before_closer_other_category
        closer_other = report(latitude: 44.7561, longitude: 19.216, category: "rasvjeta")
        same_category = report(latitude: 44.7565, longitude: 19.216, category: "putevi")

        matches = finder_with([closer_other, same_category])
                  .matches(organization:, latitude: 44.756, longitude: 19.216, category: "putevi")

        assert_equal [same_category, closer_other], matches
      end

      def test_without_query_category_nearest_candidate_wins
        closer = report(latitude: 44.7561, longitude: 19.216, category: "rasvjeta")
        farther = report(latitude: 44.7565, longitude: 19.216, category: "putevi")

        matches = finder_with([farther, closer])
                  .matches(organization:, latitude: 44.756, longitude: 19.216, category: nil)

        assert_equal [closer, farther], matches
      end

      def test_call_returns_the_best_match
        closer = report(latitude: 44.7561, longitude: 19.216, category: "rasvjeta")
        same_category = report(latitude: 44.7565, longitude: 19.216, category: "putevi")

        result = finder_with([closer, same_category])
                 .call(organization:, latitude: 44.756, longitude: 19.216, category: "putevi")

        assert_same same_category, result
      end

      private

      def finder_with(candidates)
        PureDuplicateFinder.new(candidates:)
      end

      def organization
        OrgStub.new(id: 1)
      end

      def report(latitude:, longitude:, category:)
        ReportStub.new(latitude:, longitude:, category:)
      end
    end
  end
end

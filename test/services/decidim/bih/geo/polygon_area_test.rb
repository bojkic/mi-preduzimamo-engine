# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/geo/polygon_area"

module Decidim
  module Bih
    module Geo
      class PolygonAreaTest < Minitest::Test
        # A 2×2 axis-aligned square at the origin.
        SQUARE = {
          "type" => "Polygon",
          "coordinates" => [[[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0], [0.0, 0.0]]]
        }.freeze

        # Covers the LEFT HALF of SQUARE.
        LEFT_HALF = {
          "type" => "Polygon",
          "coordinates" => [[[-1.0, -1.0], [1.0, -1.0], [1.0, 3.0], [-1.0, 3.0], [-1.0, -1.0]]]
        }.freeze

        # SQUARE with a 1×1 hole in the middle → area 3, not 4.
        SQUARE_WITH_HOLE = {
          "type" => "Polygon",
          "coordinates" => [
            [[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0], [0.0, 0.0]],
            [[0.5, 0.5], [1.5, 0.5], [1.5, 1.5], [0.5, 1.5], [0.5, 0.5]]
          ]
        }.freeze

        TWO_SQUARES = {
          "type" => "MultiPolygon",
          "coordinates" => [
            [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]],
            [[[5.0, 0.0], [6.0, 0.0], [6.0, 1.0], [5.0, 1.0], [5.0, 0.0]]]
          ]
        }.freeze

        def test_area_of_a_square
          assert_in_delta 4.0, PolygonArea.area(SQUARE), 0.001
        end

        def test_area_subtracts_holes
          assert_in_delta 3.0, PolygonArea.area(SQUARE_WITH_HOLE), 0.001
        end

        def test_area_of_a_multipolygon_sums_the_parts
          assert_in_delta 2.0, PolygonArea.area(TWO_SQUARES), 0.001
        end

        def test_covered_ratio_is_one_half_for_a_half_covering_clip
          assert_in_delta 0.5, PolygonArea.covered_ratio(SQUARE, LEFT_HALF), 0.001
        end

        def test_covered_ratio_is_one_when_the_clip_contains_the_polygon
          big = {
            "type" => "Polygon",
            "coordinates" => [[[-9.0, -9.0], [9.0, -9.0], [9.0, 9.0], [-9.0, 9.0], [-9.0, -9.0]]]
          }
          assert_in_delta 1.0, PolygonArea.covered_ratio(SQUARE, big), 0.001
        end

        def test_covered_ratio_is_zero_for_a_disjoint_clip
          far = {
            "type" => "Polygon",
            "coordinates" => [[[50.0, 50.0], [51.0, 50.0], [51.0, 51.0], [50.0, 51.0], [50.0, 50.0]]]
          }
          assert_in_delta 0.0, PolygonArea.covered_ratio(SQUARE, far), 0.001
        end

        # A ring given without an explicit closing point must still be closed.
        def test_unclosed_ring_is_closed_implicitly
          open_square = {
            "type" => "Polygon",
            "coordinates" => [[[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 2.0]]]
          }
          assert_in_delta 4.0, PolygonArea.area(open_square), 0.001
        end

        def test_degenerate_geometry_has_zero_area_and_zero_ratio
          flat = { "type" => "Polygon", "coordinates" => [[[0.0, 1.0], [2.0, 1.0], [0.0, 1.0]]] }

          assert_in_delta 0.0, PolygonArea.area(flat), 0.001
          assert_in_delta 0.0, PolygonArea.covered_ratio(flat, SQUARE), 0.001
        end

        def test_clip_index_matches_the_unindexed_span_computation
          index = PolygonArea::ClipIndex.new(LEFT_HALF)
          edges = PolygonArea.edges(LEFT_HALF)

          assert_equal PolygonArea.spans_at(edges, 0.5), index.spans_at(0.5)
        end

        def test_covered_ratio_accepts_a_prebuilt_clip_index
          index = PolygonArea::ClipIndex.new(LEFT_HALF)

          assert_in_delta 0.5, PolygonArea.covered_ratio(SQUARE, index), 0.001
        end

        # Tests with slanted edges: spans_at must interpolate across y-coordinates.
        # Axis-aligned rectangles never interpolate, so bugs in the interpolation
        # arithmetic would have passed the original test suite undetected.

        def test_area_of_a_right_triangle
          # Right triangle with vertices (0,0), (2,0), (0,2).
          # Exact area = 0.5 * base * height = 0.5 * 2 * 2 = 2.0
          # Hypotenuse from (2,0) to (0,2) is slanted; spans_at must interpolate
          # the crossing x-coordinates for every scanline between y=0 and y=2.
          triangle = {
            "type" => "Polygon",
            "coordinates" => [[[0.0, 0.0], [2.0, 0.0], [0.0, 2.0], [0.0, 0.0]]]
          }
          assert_in_delta 2.0, PolygonArea.area(triangle), 0.001
        end

        def test_area_of_a_rotated_diamond
          # Diamond with vertices (1,0), (2,1), (1,2), (0,1).
          # This is a unit square rotated 45 degrees.
          # Exact area = side^2 = (√2)^2 = 2.0
          # All four edges are slanted, forcing full interpolation coverage.
          diamond = {
            "type" => "Polygon",
            "coordinates" => [[[1.0, 0.0], [2.0, 1.0], [1.0, 2.0], [0.0, 1.0], [1.0, 0.0]]]
          }
          assert_in_delta 2.0, PolygonArea.area(diamond), 0.001
        end

        def test_covered_ratio_with_slanted_clip
          # Clip: right triangle with vertices (0,0), (2,0), (2,2).
          # Hypotenuse from (0,0) to (2,2) is slanted at 45 degrees.
          # Area of clip = 0.5 * 2 * 2 = 2.0
          # This triangle covers exactly the right half of SQUARE (0,0)-(2,2).
          # Intersection area = 2.0, so covered_ratio = 2.0 / 4.0 = 0.5
          slanted_clip = {
            "type" => "Polygon",
            "coordinates" => [[[0.0, 0.0], [2.0, 0.0], [2.0, 2.0], [0.0, 0.0]]]
          }
          assert_in_delta 0.5, PolygonArea.covered_ratio(SQUARE, slanted_clip), 0.001
        end

        def test_area_of_regular_polygon_discretization
          # Regular 64-gon inscribed in a circle of radius 1.
          # Area of regular n-gon: A = 0.5 * n * r^2 * sin(2π/n)
          # For n=64, r=1: A = 32 * sin(π/32) ≈ 3.1361
          # As n→∞, area → π. For n=64, we're close enough to test scanline quality:
          # with scanlines=600, we should hit within 0.001; with scanlines=20, we'd miss.
          n = 64
          expected_area = 0.5 * n * Math.sin(2 * Math::PI / n)

          vertices = (0...n).map do |i|
            angle = 2 * Math::PI * i / n
            [Math.cos(angle), Math.sin(angle)]
          end
          vertices << vertices.first

          polygon = {
            "type" => "Polygon",
            "coordinates" => [vertices]
          }

          assert_in_delta expected_area, PolygonArea.area(polygon), 0.001
        end
      end
    end
  end
end

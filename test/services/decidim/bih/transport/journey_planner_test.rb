# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/time/conversions"
require_relative "../../../../../lib/decidim/bih/transliterator"
require_relative "../../../../../app/services/decidim/bih/transport/walking_estimate"
require_relative "../../../../../app/services/decidim/bih/transport/nearby_stops"
require_relative "../../../../../app/services/decidim/bih/transport/timetable_snapshot"
require_relative "../../../../../app/services/decidim/bih/transport/journey_query"
require_relative "../../../../../app/services/decidim/bih/transport/journey_planner"
require_relative "../../../../../app/services/decidim/bih/transport/stop_resolver"

module Decidim
  module Bih
    module Transport
      class JourneyPlannerTest < Minitest::Test
        def test_farther_boarding_point_wins_after_access_walk_and_arrival
          snapshot = snapshot_for(
            stops: %w(near far end),
            trips: [trip("slow", "G1", ["near", "09:03"], ["end", "09:30"]),
                    trip("fast", "G2", ["far", "09:06"], ["end", "09:12"])])
          query = JourneyQuery.new(starts: [{ stop_id: "near", walk_seconds: 45, boarding_margin_seconds: 60, distance_meters: 40 },
                                             { stop_id: "far", walk_seconds: 185, boarding_margin_seconds: 60, distance_meters: 170 }],
                                   finishes: [{ stop_id: "end" }], requested_at: clock("09:00"))
          result = JourneyPlanner.new(snapshot).call(query)

          assert result.search_complete
          assert_equal "fast", result.journeys.first.fetch(:legs).first.fetch(:trip_id)
          assert_equal clock("09:12"), result.journeys.first.fetch(:arrival_at)
          assert_equal clock("09:01:55"), result.journeys.first.fetch(:leave_at)
        end

        def test_missed_transfer_is_excluded_and_realistic_transfer_beats_direct
          snapshot = snapshot_for(
            stops: %w(start exchange end),
            trips: [trip("first", "P1", ["start", "09:05"], ["exchange", "09:10"]),
                    trip("missed", "P8", ["exchange", "09:09"], ["end", "09:19"]),
                    trip("possible", "P8", ["exchange", "09:15"], ["end", "09:25"]),
                    trip("direct", "P2", ["start", "09:04"], ["end", "09:30"])])
          query = JourneyQuery.new(starts: [{ stop_id: "start" }], finishes: [{ stop_id: "end" }], requested_at: clock("09:00"))
          result = JourneyPlanner.new(snapshot).call(query)

          assert result.search_complete
          assert_equal %w(first possible), result.journeys.first.fetch(:legs).map { |leg| leg.fetch(:trip_id) }
          assert_equal clock("09:25"), result.journeys.first.fetch(:arrival_at)
          direct = JourneyPlanner.new(snapshot).call(JourneyQuery.new(starts: [{ stop_id: "start" }], finishes: [{ stop_id: "end" }],
                                                                     requested_at: clock("09:00"), direct_only: true))
          assert_equal ["direct"], direct.journeys.first.fetch(:legs).map { |leg| leg.fetch(:trip_id) }
        end

        def test_singular_place_selects_central_stop_and_discloses_alternatives
          resolver = StopResolver.new(stops: [{ id: "janja-centar", label: "Janja (centar)" },
                                             { id: "janja-skola", label: "Janja (škola)" }],
                                      places: [{ id: "place:janja", name: "Janja", aliases: ["Janje"],
                                                 member_stop_ids: %w(janja-centar janja-skola), default_stop_ids: ["janja-centar"],
                                                 default_label: "Janja (centar)", assumption_reason: "printed_centre" }])
          result = resolver.resolve("Јањe")
          assert_equal :ok, result.status
          assert_equal "Janja (centar)", result.selected.fetch(:label)
          assert_equal "printed_centre", result.assumption_reason
          assert_equal ["Janja (škola)"], result.alternatives.map { |row| row.fetch(:label) }
        end

        def test_stop_name_with_parentheses_matches_parser_text_without_parentheses
          resolver = StopResolver.new(stops: [{ id: "janja-centar", label: "Janja (centar)", aliases: ["Janje (centar)"] }])
          assert_equal "janja-centar", resolver.resolve("Janje (centar)").selected.fetch(:id)
          assert_equal "janja-centar", resolver.resolve("janje centar").selected.fetch(:id)
          assert_equal "janja-centar", resolver.resolve("  Јање — центар!  ").selected.fetch(:id)
        end

        def test_spatial_grid_keeps_exact_radius_boundary_and_distinct_points
          origin = { latitude: 44.7648, longitude: 19.2105 }
          near = { id: "near", label: "same", latitude: 44.7648, longitude: 19.2105 }
          far = { id: "far", label: "same", latitude: 44.7666, longitude: 19.2105 }
          index = NearbyStops.new([near, far])
          radius = WalkingEstimate.distance_meters(origin, far)

          assert_equal %w(near far), index.within(origin, radius_meters: radius).map { |stop, _| stop.fetch(:id) }
          assert_equal ["near"], index.within(origin, radius_meters: radius - 1).map { |stop, _| stop.fetch(:id) }
        end

        private

        def clock(value)
          hour, minute, second = value.split(":").map(&:to_i)
          Time.utc(2026, 9, 17, hour, minute, second || 0)
        end

        def trip(id, route, *points)
          { id:, route_code: route, source_url: "https://example.test/#{route}", direction: "A", calendar: { "kind" => "school_day" },
            source_column_index: 0, calls: points.each_with_index.map do |(stop, time), index|
              { stop_id: stop, at: clock(time), source_row_index: index }
            end }
        end

        def snapshot_for(stops:, trips:)
          TimetableSnapshot.new(revision: "fixture-v1", service_date: "2026-09-17", stops: stops.map { |id| { id:, label: id } }, trips:)
        end
      end
    end
  end
end

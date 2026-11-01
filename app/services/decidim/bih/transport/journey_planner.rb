# frozen_string_literal: true

require_relative "walking_estimate"

module Decidim
  module Bih
    module Transport
      # Bounded connection scan over immutable trip calls. All boarding stops
      # share one chronological pass. A completed scan proves the best option
      # only within the reviewed radius, calendars and one-link transfer scope.
      class JourneyPlanner
        MAX_TRANSFER_WAIT_SECONDS = 14_400
        MAX_COMBINATIONS = 200_000
        Result = Struct.new(:status, :journeys, :search_complete, :reason, :connections_considered,
                            :combinations_considered, :max_label_frontier, :final_label_frontier,
                            :transfer_relaxations, :transfer_comparisons, :transfer_precheck_comparisons, keyword_init: true)

        def initialize(snapshot)
          @snapshot = snapshot
        end

        def call(query)
          @combinations = 0
          @connections = 0
          @queued_first = 0
          @queued_second = 0
          @queued_transfer = 0
          @processing_labels = 0
          @max_label_frontier = 0
          @transfer_relaxations = 0
          @transfer_comparisons = 0
          @transfer_precheck_comparisons = 0
          @complete = true
          @journeys = []
          @egress = query.finishes.to_h { |entry| [entry.fetch(:stop_id), entry] }
          @transfer_links = transfer_index
          @starts_by_stop = query.starts.group_by { |start| start.fetch(:stop_id) }
          @transfer_ready = Hash.new { |hash, key| hash[key] = [] }
          @first_onboard = Hash.new { |hash, key| hash[key] = [] }
          @second_onboard = Hash.new { |hash, key| hash[key] = [] }
          first_index = @snapshot.connections.bsearch_index do |trip, index|
            trip.fetch(:calls)[index].fetch(:at) >= query.requested_at
          end || @snapshot.connections.size
          @snapshot.connections.drop(first_index).each do |trip, from_index|
            scan_connection(trip, from_index, query)
            break unless @complete
          end
          selected = @journeys.uniq { |journey| signature(journey) }
                              .sort_by { |journey| ranking(journey, query.mode) }.first(query.limit)
          Result.new(status: selected.empty? ? :empty : :ok, journeys: selected, search_complete: @complete,
                     reason: @complete ? (selected.empty? ? "no_eligible_trip_in_reviewed_scope" : nil) : "incomplete_search",
                     connections_considered: @connections, combinations_considered: @combinations,
                     max_label_frontier: @max_label_frontier, final_label_frontier: label_frontier,
                     transfer_relaxations: @transfer_relaxations, transfer_comparisons: @transfer_comparisons,
                     transfer_precheck_comparisons: @transfer_precheck_comparisons)
        end

        private

        def scan_connection(trip, from_index, query)
          @connections += 1
          return if query.route_code && trip.fetch(:route_code) != query.route_code
          return if query.direction && trip.fetch(:direction) != query.direction

          calls = trip.fetch(:calls)
          first = calls.fetch(from_index)
          last = calls.fetch(from_index + 1)
          key = [trip.fetch(:id), from_index]
          first_paths = @first_onboard.delete(key) || []
          second_paths = @second_onboard.delete(key) || []
          @queued_first -= first_paths.size
          @queued_second -= second_paths.size
          first_paths.concat(origin_boardings(trip, from_index, first, query))
          second_paths.concat(transfer_boardings(trip, from_index, first)) unless query.direct_only
          return unless @complete

          @processing_labels = first_paths.size + second_paths.size
          track_frontier!

          first_paths.each do |path|
            @processing_labels -= 1
            return unless budget!

            extended = extend_path(path, trip, from_index, last)
            add_destination(extended, last, query)
            unless query.direct_only
              return unless prepare_transfers(extended, last, query)
            end
            if from_index + 1 < calls.size - 1
              @first_onboard[[trip.fetch(:id), from_index + 1]] << extended
              @queued_first += 1
              track_frontier!
            end
          end
          second_paths.each do |path|
            @processing_labels -= 1
            return unless budget!

            extended = extend_path(path, trip, from_index, last)
            add_destination(extended, last, query)
            if from_index + 1 < calls.size - 1
              @second_onboard[[trip.fetch(:id), from_index + 1]] << extended
              @queued_second += 1
              track_frontier!
            end
          end
        end

        def origin_boardings(trip, from_index, departure, query)
          @starts_by_stop.fetch(departure.fetch(:stop_id), []).filter_map do |start|
            ready = query.requested_at + start.fetch(:walk_seconds) + start.fetch(:boarding_margin_seconds)
            # Boarding feasibility and the citizen's strict clock boundary are separate conditions.
            next if departure.fetch(:at) < ready
            next if query.strict && departure.fetch(:at) <= query.requested_at

            { legs: [leg(trip, from_index, nil)],
              leave_at: departure.fetch(:at) - start.fetch(:walk_seconds) - start.fetch(:boarding_margin_seconds),
              first_departure_at: departure.fetch(:at), access_walk_seconds: start.fetch(:walk_seconds),
              transfer_walk_seconds: 0, transfer_margin_seconds: 0,
              access_distance_meters: start.fetch(:distance_meters) }
          end
        end

        def transfer_boardings(trip, from_index, departure)
          ready = @transfer_ready.fetch(departure.fetch(:stop_id), [])
          retained = []
          boardings = []
          ready.each do |transfer|
            # Dense stops can contain many future-ready labels; every comparison consumes the search budget.
            @transfer_comparisons += 1
            return [] unless budget!

            next if transfer.fetch(:ready_at) + MAX_TRANSFER_WAIT_SECONDS < departure.fetch(:at)

            retained << transfer
            path = transfer.fetch(:path)
            next if trip.fetch(:id) == path.fetch(:legs).first.fetch(:trip_id)

            wait = departure.fetch(:at) - transfer.fetch(:ready_at)
            next if wait.negative? || wait > MAX_TRANSFER_WAIT_SECONDS

            boardings << path.merge(legs: path.fetch(:legs) + [leg(trip, from_index, nil)],
                                    transfer_walk_seconds: transfer.fetch(:walk_seconds),
                                    transfer_margin_seconds: transfer.fetch(:margin_seconds),
                                    transfer_kind: transfer.fetch(:estimate_kind), transfer_wait_seconds: wait)
          end
          @transfer_ready[departure.fetch(:stop_id)] = retained
          @queued_transfer -= ready.size - retained.size
          boardings
        end

        def extend_path(path, trip, from_index, arrival)
          current = path.fetch(:legs).last.merge(to_index: from_index + 1,
                                                  destination_stop_id: arrival.fetch(:stop_id), arrival_at: arrival.fetch(:at),
                                                  source_row_to: arrival.fetch(:source_row_index))
          path.merge(legs: path.fetch(:legs)[0...-1] + [current])
        end

        def prepare_transfers(path, arrival, query)
          first_trip_id = path.fetch(:legs).first.fetch(:trip_id)
          @transfer_links.fetch(arrival.fetch(:stop_id), []).each do |link|
            ready_at = arrival.fetch(:at) + link.fetch(:walk_seconds) + link.fetch(:margin_seconds)
            available = another_trip_available?(link.fetch(:to_stop_id), ready_at, first_trip_id, query.route_code, query.direction)
            return false unless @complete
            next unless available
            return false unless budget!

            @transfer_ready[link.fetch(:to_stop_id)] << {
              path:, ready_at:,
              walk_seconds: link.fetch(:walk_seconds), margin_seconds: link.fetch(:margin_seconds),
              estimate_kind: link.fetch(:estimate_kind)
            }
            @queued_transfer += 1
            @transfer_relaxations += 1
            track_frontier!
          end
          true
        end

        def another_trip_available?(stop_id, ready_at, first_trip_id, route_code, direction)
          departures = @snapshot.departures_by_stop.fetch(stop_id, [])
          index = departures.bsearch_index { |trip, position| trip.fetch(:calls)[position].fetch(:at) >= ready_at }
          return false unless index

          last_boarding_at = ready_at + MAX_TRANSFER_WAIT_SECONDS
          index.upto(departures.size - 1) do |position_in_index|
            # A dense stop can have many in-window departures before a usable
            # different trip; count that work against the same search budget.
            @transfer_precheck_comparisons += 1
            return false unless budget!

            trip, position = departures.fetch(position_in_index)
            return false if trip.fetch(:calls)[position].fetch(:at) > last_boarding_at
            return true if trip.fetch(:id) != first_trip_id && (!route_code || trip.fetch(:route_code) == route_code) &&
                           (!direction || trip.fetch(:direction) == direction)
          end
          false
        end

        def add_destination(base, arrival, query)
          egress = @egress[arrival.fetch(:stop_id)]
          return unless egress

          arrival_at = arrival.fetch(:at) + egress.fetch(:walk_seconds)
          legs = base.fetch(:legs)
          ride_seconds = legs.sum { |item| (item.fetch(:arrival_at) - item.fetch(:departure_at)).to_i }
          transfer_gap = legs.size > 1 ? (legs.last.fetch(:departure_at) - legs.first.fetch(:arrival_at)).to_i : 0
          walking = base.fetch(:access_walk_seconds) + base.fetch(:transfer_walk_seconds) + egress.fetch(:walk_seconds)
          ranges = [base.fetch(:access_walk_seconds), base.fetch(:transfer_walk_seconds), egress.fetch(:walk_seconds)]
                   .map { |seconds| WalkingEstimate.range_for_seconds(seconds) }
          walk_range = { "version" => WalkingEstimate::RANGE_VERSION,
                         "low" => ranges.sum { |range| range.fetch("low") },
                         "high" => ranges.sum { |range| range.fetch("high") } }
          transfer_high = ranges.fetch(1).fetch("high")
          close_transfer = legs.size > 1 && transfer_gap <= transfer_high + base.fetch(:transfer_margin_seconds)
          waiting = [(legs.first.fetch(:departure_at) - base.fetch(:leave_at)).to_i - base.fetch(:access_walk_seconds), 0].max +
                    [transfer_gap - base.fetch(:transfer_walk_seconds), 0].max
          candidate = base.merge(arrival_at:, egress_walk_seconds: egress.fetch(:walk_seconds),
                                 egress_distance_meters: egress.fetch(:distance_meters), walking_seconds: walking,
                                 walking_estimate_range_seconds: walk_range, close_transfer_warning: close_transfer,
                                 waiting_seconds: waiting, ride_seconds:, transfer_count: legs.size - 1)
          previous = @journeys.find { |journey| signature(journey) == signature(candidate) }
          return if previous && (ranking(previous, query.mode) <=> ranking(candidate, query.mode)) <= 0

          @journeys.delete(previous) if previous
          @journeys << candidate
          @journeys.sort_by! { |journey| ranking(journey, query.mode) }
          @journeys.pop while @journeys.size > query.limit
        end

        def leg(trip, from_index, to_index)
          calls = trip.fetch(:calls)
          from = calls[from_index]
          to = to_index ? calls[to_index] : nil
          { trip_id: trip.fetch(:id), route_code: trip.fetch(:route_code), source_url: trip.fetch(:source_url),
            direction: trip.fetch(:direction), calendar: trip.fetch(:calendar),
            origin_stop_id: from.fetch(:stop_id), destination_stop_id: to&.fetch(:stop_id),
            departure_at: from.fetch(:at), arrival_at: to&.fetch(:at), from_index:, to_index:,
            source_column_index: trip.fetch(:source_column_index),
            source_row_from: from.fetch(:source_row_index), source_row_to: to&.fetch(:source_row_index) }
        end

        def transfer_index
          index = Hash.new { |hash, key| hash[key] = [] }
          @snapshot.transfers.each { |link| index[link.fetch(:from_stop_id)] << link }
          @snapshot.stops.each_key do |id|
            index[id] << { from_stop_id: id, to_stop_id: id, walk_seconds: 0,
                           margin_seconds: 180, estimate_kind: "same_boarding_point_policy" }.freeze
          end
          index.each_value(&:freeze)
          index
        end

        def budget!
          @combinations += 1
          @complete = false if @combinations > MAX_COMBINATIONS
          @complete
        end

        def label_frontier
          @queued_first + @queued_second + @queued_transfer + @processing_labels
        end

        def track_frontier!
          @max_label_frontier = [@max_label_frontier, label_frontier].max
        end

        def signature(journey)
          [journey.fetch(:legs).map { |leg| [leg.fetch(:trip_id), leg.fetch(:origin_stop_id), leg.fetch(:destination_stop_id)] },
           journey.fetch(:arrival_at).to_i]
        end

        def ranking(journey, mode)
          first = journey.fetch(:first_departure_at).to_f
          arrival = journey.fetch(:arrival_at).to_f
          common = [journey.fetch(:transfer_count), -journey.fetch(:leave_at).to_f,
                    journey.fetch(:walking_seconds), signature(journey).to_s]
          case mode
          when :next then [first, arrival, *common]
          when :last then [-first, arrival, *common]
          else [arrival, *common]
          end
        end
      end
    end
  end
end

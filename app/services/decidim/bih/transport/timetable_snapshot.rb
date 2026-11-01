# frozen_string_literal: true

module Decidim
  module Bih
    module Transport
      # Immutable, public, single-service-day search data. The host authorizes
      # its prepared sources before construction and again before delivery.
      class TimetableSnapshot
        attr_reader :revision, :service_date, :stops, :trips, :transfers, :nearby, :departures_by_stop, :connections

        def initialize(revision:, service_date:, stops:, trips:, transfers: [])
          @revision = String(revision).freeze
          @service_date = String(service_date).freeze
          @stops = Array(stops).map { |row| symbolize(row).freeze }.to_h { |row| [row.fetch(:id), row] }.freeze
          @trips = Array(trips).map do |trip|
            row = symbolize(trip)
            row[:calls] = Array(row.fetch(:calls)).map { |call| symbolize(call).freeze }.freeze
            row.freeze
          end.freeze
          @transfers = Array(transfers).map { |row| symbolize(row).freeze }.freeze
          @nearby = NearbyStops.new(@stops.values)
          @departures_by_stop = build_departure_index.freeze
          @connections = build_connections.freeze
          freeze
        end

        def point_ids_for(public_id)
          @stops.values.filter_map { |stop| stop[:id] if stop[:id] == public_id || stop[:public_id] == public_id || stop[:station_id] == public_id }
        end

        private

        def symbolize(row)
          row.transform_keys(&:to_sym)
        end

        def build_departure_index
          index = Hash.new { |hash, key| hash[key] = [] }
          @trips.each do |trip|
            trip.fetch(:calls).each_with_index do |call, position|
              next if position == trip.fetch(:calls).size - 1

              index[call.fetch(:stop_id)] << [trip, position]
            end
          end
          index.each_value do |departures|
            departures.sort_by! { |trip, position| [trip.fetch(:calls)[position].fetch(:at).to_f, trip.fetch(:id)] }
            departures.freeze
          end
          index
        end

        def build_connections
          @trips.flat_map do |trip|
            (0...(trip.fetch(:calls).size - 1)).map { |index| [trip, index].freeze }
          end.sort_by { |trip, index| [trip.fetch(:calls)[index].fetch(:at).to_f, trip.fetch(:id), index] }
        end
      end
    end
  end
end

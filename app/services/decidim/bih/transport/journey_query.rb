# frozen_string_literal: true

module Decidim
  module Bih
    module Transport
      # All endpoint coordinates stay in this request object, never in the
      # shared timetable snapshot or cache key.
      class JourneyQuery
        MODES = %i[fastest next last].freeze
        attr_reader :starts, :finishes, :requested_at, :mode, :route_code, :direction, :direct_only, :strict, :limit

        def initialize(starts:, finishes:, requested_at:, mode: :fastest, route_code: nil, direction: nil, direct_only: false, strict: true, limit: 2)
          @starts = normalize_candidates(starts)
          @finishes = normalize_candidates(finishes)
          @requested_at = requested_at
          @mode = mode.to_sym
          raise ArgumentError, "unsupported journey mode" unless MODES.include?(@mode)
          raise ArgumentError, "requested_at must be a Time" unless requested_at.respond_to?(:to_time)
          raise ArgumentError, "empty journey endpoints" if @starts.empty? || @finishes.empty?

          @route_code = route_code
          @direction = direction
          raise ArgumentError, "unsupported route direction" if direction && !%w(A B).include?(direction)
          @direct_only = direct_only == true
          @strict = strict == true
          @limit = Integer(limit).clamp(1, 3)
          freeze
        end

        private

        def normalize_candidates(values)
          Array(values).map do |value|
            row = value.transform_keys(&:to_sym)
            { stop_id: String(row.fetch(:stop_id)), walk_seconds: Integer(row.fetch(:walk_seconds, 0)),
              boarding_margin_seconds: Integer(row.fetch(:boarding_margin_seconds, 0)),
              distance_meters: Integer(row.fetch(:distance_meters, 0)) }.freeze
          end.uniq { |candidate| candidate.fetch(:stop_id) }.freeze
        end
      end
    end
  end
end

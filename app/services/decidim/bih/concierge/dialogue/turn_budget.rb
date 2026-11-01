# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # One monotonic wall-clock budget shared by every part of a citizen turn.
        # Child budgets cap one dependency without extending the parent deadline.
        class TurnBudget
          DEFAULT_TIMEOUT = 10.0
          MAX_TIMEOUT = DEFAULT_TIMEOUT

          attr_reader :deadline

          def initialize(timeout: DEFAULT_TIMEOUT, clock: nil)
            @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @deadline = read_clock + duration!(timeout, maximum: MAX_TIMEOUT)
          end

          def remaining_seconds
            [deadline - read_clock, 0.0].max
          end

          def expired?
            remaining_seconds <= 0.0
          end

          # Returns a child budget, never a numeric duration. Passing a bare
          # monotonic timestamp between components is too easy to mistake for a
          # duration and can silently defeat expiry.
          def within(max_seconds)
            child_deadline = [deadline, read_clock + duration!(max_seconds)].min
            self.class.send(:from_deadline, deadline: child_deadline, clock: @clock)
          end

          class << self
            private

            def from_deadline(deadline:, clock:)
              instance = allocate
              instance.send(:initialize_from_deadline, deadline:, clock:)
              instance
            end
          end

          private

          def initialize_from_deadline(deadline:, clock:)
            @clock = clock
            @deadline = deadline
          end

          def read_clock
            value = Float(@clock.call)
            raise ArgumentError, "Monotonic clock must be finite" unless value.finite?

            value
          rescue TypeError, ArgumentError
            raise ArgumentError, "Monotonic clock is invalid"
          end

          def duration!(value, maximum: nil)
            duration = Float(value)
            raise ArgumentError, "Timeout must be finite and positive" unless duration.finite? && duration.positive?
            raise ArgumentError, "Timeout exceeds maximum" if maximum && duration > maximum

            duration
          rescue TypeError, ArgumentError
            raise ArgumentError, "Timeout must be finite and positive"
          end
        end
      end
    end
  end
end

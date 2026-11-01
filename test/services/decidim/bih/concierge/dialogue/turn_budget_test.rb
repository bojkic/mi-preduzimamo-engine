# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/turn_budget"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class TurnBudgetTest < Minitest::Test
          class Clock
            attr_accessor :now

            def initialize(now = 100.0) = (@now = now)

            def call = now
          end

          def setup
            @clock = Clock.new
            @budget = TurnBudget.new(timeout: 10, clock: @clock)
          end

          def test_tracks_one_absolute_monotonic_deadline
            assert_in_delta 110.0, @budget.deadline
            assert_in_delta 10.0, @budget.remaining_seconds

            @clock.now = 103.25
            assert_in_delta 6.75, @budget.remaining_seconds
            refute @budget.expired?
          end

          def test_expires_at_the_exact_deadline_and_never_returns_negative_time
            @clock.now = 110.0
            assert @budget.expired?
            assert_equal 0.0, @budget.remaining_seconds

            @clock.now = 150.0
            assert_equal 0.0, @budget.remaining_seconds
          end

          def test_within_returns_a_child_budget_capped_from_now
            @clock.now = 102.0
            child = @budget.within(3)

            assert_instance_of TurnBudget, child
            assert_in_delta 105.0, child.deadline
            assert_in_delta 3.0, child.remaining_seconds
            assert_in_delta 8.0, @budget.remaining_seconds
          end

          def test_child_can_never_extend_parent_deadline
            @clock.now = 108.0
            child = @budget.within(6)

            assert_in_delta @budget.deadline, child.deadline
            @clock.now = 110.0
            assert child.expired?
          end

          def test_rejects_invalid_timeout_and_clock_values
            [nil, 0, -1, TurnBudget::MAX_TIMEOUT + 0.01, Float::INFINITY, "not-a-number"].each do |timeout|
              assert_raises(ArgumentError) { TurnBudget.new(timeout:, clock: @clock) }
            end

            bad_clock = -> { Float::NAN }
            assert_raises(ArgumentError) { TurnBudget.new(timeout: 1, clock: bad_clock) }
            assert_raises(ArgumentError) { @budget.within(0) }
          end
        end
      end
    end
  end
end

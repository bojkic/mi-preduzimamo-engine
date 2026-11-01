# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/review_decision"

module Decidim
  module Bih
    class ReviewDecisionTest < Minitest::Test
      class TransactionModel
        class << self
          attr_reader :events

          def reset!
            @events = []
            @open = false
          end

          def open?
            @open
          end

          def transaction
            @events << :begin
            @open = true
            yield
          ensure
            @open = false
            @events << :end
          end
        end
      end

      class Decision < ReviewDecision
        attr_reader :events, :transaction_model

        def initialize(guards: [], transaction_model: nil, perform_error: nil)
          super()
          @guard_specs = guards
          @transaction_model = transaction_model
          @perform_error = perform_error
          @events = []
        end

        private

        def guards
          @guard_specs.map do |status, result|
            [
              status,
              lambda do
                @events << [:guard, status]
                result
              end
            ]
          end
        end

        def perform
          @events << [:perform, transaction_model&.open? || false]
          raise @perform_error if @perform_error
        end

        def notify
          @events << [:notify, transaction_model&.open? || false]
        end
      end

      def setup
        TransactionModel.reset!
      end

      def test_first_matching_guard_short_circuits_without_transition_or_notification
        decision = Decision.new(guards: [[:missing, true], [:invalid, true]])

        assert_equal :missing, decision.call
        assert_equal [[:guard, :missing]], decision.events
      end

      def test_guards_run_in_order_until_one_matches
        decision = Decision.new(guards: [[:missing, false], [:already, true], [:invalid, true]])

        assert_equal :already, decision.call
        assert_equal [[:guard, :missing], [:guard, :already]], decision.events
      end

      def test_no_matching_guard_runs_transition_then_notification
        decision = Decision.new(guards: [[:missing, false], [:already, false]])

        assert_equal :ok, decision.call
        assert_equal [[:guard, :missing], [:guard, :already], [:perform, false], [:notify, false]], decision.events
      end

      def test_transaction_model_wraps_transition_but_not_notification
        decision = Decision.new(transaction_model: TransactionModel)

        assert_equal :ok, decision.call
        assert_equal [:begin, :end], TransactionModel.events
        assert_equal [[:perform, true], [:notify, false]], decision.events
      end

      def test_perform_failure_closes_transaction_and_skips_notification
        error = StandardError.new("transition failed")
        decision = Decision.new(transaction_model: TransactionModel, perform_error: error)

        raised = assert_raises(StandardError) { decision.call }

        assert_same error, raised
        assert_equal [:begin, :end], TransactionModel.events
        assert_equal [[:perform, true]], decision.events
      end
    end
  end
end

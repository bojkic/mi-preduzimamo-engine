# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class PreModelStagesTest < Minitest::Test
          BUILT_IN = %w(
            resume_nothing public_information_follow_up transport_walking_follow_up
            prior_evidence_follow_up service_follow_up procedure_fee_follow_up
          ).freeze
          SEAM = %w(
            accept cancelled prior_evidence_kind procedures resume_nothing
            resume_with_nothing_suspended retain_answer unavailable walking_stop_request
          ).freeze
          NOW = Time.utc(2026, 9, 14, 12)

          def setup
            @stages = PreModelStages.stages.dup
          end

          def teardown
            PreModelStages.stages.replace(@stages)
          end

          # The order is behaviour: it is the order the coordinator ran these
          # checks in before the list existed. Stages registered from other
          # files take a declared position among them and may surround them
          # (Task 2's emergency stage registers before them all, Task 3b's
          # public-information stage between two of them), but must never
          # reorder or drop them. So assert the RELATIVE order, not the list.
          def test_the_built_in_stages_keep_their_order
            assert_equal BUILT_IN, PreModelStages.stage_names & BUILT_IN
            assert_empty BUILT_IN - PreModelStages.stage_names
          end

          def test_the_first_stage_with_a_result_ends_the_walk
            reached = []
            PreModelStages.register("answers", before: "resume_nothing") do |_turn|
              reached << :first
              :answered
            end
            PreModelStages.register("never") do |_turn|
              reached << :late
              :late
            end

            assert_equal :answered, PreModelStages.walk(turn)
            assert_equal [:first], reached
          end

          def test_a_declining_stage_lets_the_next_one_try_and_an_empty_walk_returns_nil
            seen = []
            PreModelStages.stages.clear
            PreModelStages.register("declines") do |_turn|
              seen << :one
              nil
            end
            PreModelStages.register("also_declines") do |_turn|
              seen << :two
              nil
            end

            assert_nil PreModelStages.walk(turn)
            assert_equal [:one, :two], seen
          end

          def test_a_stage_can_be_placed_before_or_after_a_named_stage
            PreModelStages.register("emergency", before: "resume_nothing") { |_turn| nil }
            PreModelStages.register("after_walking", after: "transport_walking_follow_up") { |_turn| nil }
            PreModelStages.register("appended") { |_turn| nil }

            names = PreModelStages.stage_names

            assert_equal 0, names.index("emergency")
            assert_equal names.index("transport_walking_follow_up") + 1, names.index("after_walking")
            assert_equal "appended", names.last
            assert_raises(ArgumentError) { PreModelStages.register("orphan", after: "nothing") { |_turn| nil } }
          end

          def test_registering_a_known_name_replaces_it_in_place
            before = PreModelStages.stage_names
            PreModelStages.register("service_follow_up") { |_turn| nil }

            assert_equal before, PreModelStages.stage_names
            assert_equal BUILT_IN, PreModelStages.stage_names & BUILT_IN
          end

          def test_registration_refuses_a_nameless_or_handlerless_stage
            assert_raises(ArgumentError) { PreModelStages.register("") { |_turn| nil } }
            assert_raises(ArgumentError) { PreModelStages.register("no_handler") }
          end

          # A stage reaches the coordinator only through the turn's support
          # object: the procedures and the bound helpers, nothing else.
          def test_the_turn_exposes_only_the_documented_stage_seam
            assert_equal SEAM, PreModelStages::Support.members.map(&:to_s).sort
            assert_equal %w(context message state support), PreModelStages::Turn.members.map(&:to_s).sort
            assert_equal "zdravo", turn.text
            refute turn.deadline_expired?
          end

          private

          def turn
            deadline = TurnBudget.new(timeout: 10.0)
            context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, deadline:)
            PreModelStages::Turn.new(message: "zdravo", context:, state: StateStore.new.empty_state(context), support: nil)
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../../app/services/decidim/bih/concierge/dialogue/procedures/city_service"
require_relative "../../../../../../../app/services/decidim/bih/concierge/dialogue/procedures/komsiluk"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        module Procedures
          # The capability gate decides whether Milica supports the request
          # BEFORE any slot is collected: an unsupported topic is refused with
          # a next step, never asked for a day or a place.
          class CityServiceTest < Minitest::Test
            FakeResult = Data.define(:status)

            class FakeTurn
              attr_reader :action, :topic, :result, :read_calls, :clarifications, :finishes, :message, :state

              def initialize(action: "ask_information", topic: "water", supported: nil, has_location: false)
                @action = action
                @topic = topic
                @supported = supported
                @has_location = has_location
                @result = FakeResult.new(status: "ok")
                @read_calls = []
                @clarifications = []
                @finishes = []
                @message = ""
                @state = {}
              end

              def has_location? = @has_location

              def service_question_entities = {}

              def public_activity_refinement? = false

              # nil mirrors a runner built without a capabilities collaborator.
              def capability_supported?
                @supported.nil? ? true : @supported
              end

              def unsupported_topic
                finishes << [:unsupported_topic]
                [:finish, :unsupported_topic]
              end

              def read(**attributes)
                read_calls << attributes
                @result
              end

              def render_read(result)
                [:render_read, result]
              end

              def clarify(slot, key, **)
                clarifications << [slot, key]
                [:clarify, slot, key]
              end

              # Part of the Turn contract since the top-level menu gained a
              # ladder: the procedure asks for a clarification, and the runner
              # decides whether that is the menu, "which service?" or the
              # support route. The ladder itself is covered against the real
              # runner in dead_end_next_step_test.rb.
              def topic_clarification
                clarify("query", "clarify")
              end
            end

            def test_an_unsupported_topic_is_refused_before_any_slot_question_or_read
              turn = FakeTurn.new(topic: "water", supported: false)

              result = CityService.call(turn)

              assert_equal [:finish, :unsupported_topic], result
              assert_empty turn.clarifications, "an unsupported topic must never be asked for a place or a time"
              assert_empty turn.read_calls
            end

            def test_a_supported_topic_still_asks_for_the_area_when_it_needs_one
              turn = FakeTurn.new(topic: "water", supported: true)

              result = CityService.call(turn)

              assert_equal [:clarify, "area_query", "ask_area_query"], result
              assert_empty turn.finishes
            end

            def test_a_supported_topic_with_a_location_reads
              turn = FakeTurn.new(topic: "water", supported: true, has_location: true)

              result = CityService.call(turn)

              assert_equal [:render_read, turn.result], result
              assert_equal [{ action: "ask_information", entities: {} }], turn.read_calls
            end

            def test_an_unknown_topic_keeps_the_clarification_even_when_the_gate_would_refuse_it
              turn = FakeTurn.new(topic: "unknown", supported: false)

              result = CityService.call(turn)

              assert_equal [:clarify, "query", "clarify"], result
              assert_empty turn.finishes
            end

            def test_help_keeps_the_clarification_even_when_the_gate_would_refuse_it
              turn = FakeTurn.new(action: "help", topic: "water", supported: false)

              assert_equal [:clarify, "query", "clarify"], CityService.call(turn)
            end

            def test_without_a_capabilities_collaborator_the_old_behaviour_is_unchanged
              turn = FakeTurn.new(topic: "water", supported: nil)

              assert_equal [:clarify, "area_query", "ask_area_query"], CityService.call(turn)
              assert_empty turn.finishes
            end
          end
        end
      end
    end
  end
end

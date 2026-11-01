# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/civic_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class DeterministicRoutesTest < Minitest::Test
          BUILT_IN = %w(document board earning pharmacy invitation komsiluk mz_contact).freeze

          def setup
            @routes = DeterministicRoutes.routes.dup
          end

          def teardown
            DeterministicRoutes.routes.replace(@routes)
          end

          # The order is behaviour: it is the order CivicQuestion evaluated
          # these matchers in before the list existed. Routes registered from
          # other files append after them, so this asserts the built-in PREFIX
          # rather than the whole list.
          def test_the_built_in_routes_keep_their_evaluation_order
            assert_equal BUILT_IN, DeterministicRoutes.route_names.first(BUILT_IN.length)
          end

          def test_the_first_matching_route_wins_and_later_ones_never_run
            reached = []
            DeterministicRoutes.register("never_reached") do |_query, _text|
              reached << :late
              { action: "help", topic: "unknown", entities: {} }
            end

            assert_equal "goodwill", CivicQuestion.classify("kako da zaradim bodove").fetch(:topic)
            assert_empty reached, "a route after the winner must not be evaluated"
          end

          def test_a_registered_route_is_reachable_and_appends_by_default
            DeterministicRoutes.register("balance") do |query, text|
              { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "balance" } } if query == "moji bodovi"
            end

            assert_equal "balance", DeterministicRoutes.route_names.last
            assert_equal "balance", CivicQuestion.classify("moji bodovi").fetch(:entities).fetch("category")
          end

          def test_a_route_can_be_placed_before_or_after_a_named_route
            DeterministicRoutes.register("first") { |_query, _text| nil }
            DeterministicRoutes.register("before_pharmacy", before: "pharmacy") { |_query, _text| nil }
            DeterministicRoutes.register("after_board", after: "board") { |_query, _text| nil }

            names = DeterministicRoutes.route_names

            assert_equal names.index("pharmacy") - 1, names.index("before_pharmacy")
            assert_equal names.index("board") + 1, names.index("after_board")
            assert_equal "first", names.last, "a route with no anchor appends"
            assert_raises(ArgumentError) { DeterministicRoutes.register("orphan", before: "nothing") { |_q, _t| nil } }
          end

          def test_registering_a_known_name_replaces_it_in_place
            DeterministicRoutes.register("pharmacy") { |_query, _text| nil }

            assert_equal BUILT_IN, DeterministicRoutes.route_names.first(BUILT_IN.length)
            assert_nil CivicQuestion.classify("ima li dezurna apoteka nocas")
          end

          def test_registration_refuses_a_nameless_or_handlerless_route
            assert_raises(ArgumentError) { DeterministicRoutes.register("") { |_q, _t| nil } }
            assert_raises(ArgumentError) { DeterministicRoutes.register("no_matcher") }
          end

          # Each built-in route still answers exactly what it answered before
          # the extraction, and nothing else does.
          def test_each_built_in_route_selects_its_own_read
            {
              "kako da izvadim rodni list" => %w(ask_information city_service),
              "ima li obavjestenja na tabli mog komsiluka" => %w(neighborhood_information neighborhood),
              "kako da zaradim bodove" => %w(ask_information goodwill),
              "ima li dezurna apoteka nocas" => %w(ask_information health),
              "jesam li pozvan na 17.9" => %w(ask_information goodwill),
              "koji je moj komsiluk" => %w(ask_information goodwill),
              "ko je predsjednik mz Janja" => %w(choose_area neighborhood)
            }.each do |text, (action, topic)|
              read = CivicQuestion.classify(text)

              assert_equal action, read.fetch(:action), text
              assert_equal topic, read.fetch(:topic), text
            end
          end
        end
      end
    end
  end
end

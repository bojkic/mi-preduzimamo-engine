# frozen_string_literal: true

require "test_helper"
require "i18n"
require_relative "../../../../../../../app/services/decidim/bih/concierge/dialogue/procedures/komsiluk"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        module Procedures
          class KomsilukTest < Minitest::Test
            FakeResult = Data.define(:status)

            class FakeTurn
              attr_reader :action, :topic, :result, :read_calls, :clarifications, :finishes, :message, :state

              def initialize(action:, topic: "neighborhood", has_location: false, result: FakeResult.new(status: "ok"))
                @action = action
                @topic = topic
                @has_location = has_location
                @result = result
                @read_calls = []
                @clarifications = []
                @finishes = []
                @message = ""
                @state = {}
              end

              def public_activity_refinement? = false

              def has_location?
                @has_location
              end

              def read(**attributes)
                read_calls << attributes
                @result
              end

              def render_read(result)
                [:render_read, result]
              end

              def clarify(slot, key)
                clarifications << [slot, key]
                [:clarify, slot, key]
              end

              def finish(answer, **attributes)
                finishes << [answer, attributes]
                [:finish, answer, attributes]
              end

              def t(key, **_values)
                key
              end

              def destination(key)
                "/#{key}"
              end
            end

            def test_assigned_area_requests_reach_typed_neighborhood_read_without_location
              turn = FakeTurn.new(action: "neighborhood_information")

              result = Komsiluk.call(turn)

              assert_equal [:render_read, turn.result], result
              assert_equal [{ action: "neighborhood_information", topic: "neighborhood" }], turn.read_calls
              assert_empty turn.clarifications
            end

            def test_explicit_area_still_requests_the_typed_read
              turn = FakeTurn.new(action: "neighborhood_information", has_location: true)

              Komsiluk.call(turn)

              assert_equal [{ action: "neighborhood_information", topic: "neighborhood" }], turn.read_calls
              assert_empty turn.clarifications
            end

            def test_explicit_public_area_picker_still_requests_the_area_read
              turn = FakeTurn.new(action: "choose_area", has_location: true)

              Komsiluk.call(turn)

              assert_equal [{ action: "choose_area", topic: "neighborhood" }], turn.read_calls
              assert_empty turn.clarifications
            end

            def test_public_area_picker_without_area_delegates_to_authorized_read_without_inventing_an_assignment
              turn = FakeTurn.new(action: "choose_area", result: FakeResult.new(status: "empty"))

              result = Komsiluk.call(turn)

              assert_equal [:render_read, turn.result], result
              assert_equal [{ action: "choose_area", topic: "neighborhood" }], turn.read_calls
              assert_empty turn.state
              assert_empty turn.clarifications
            end

            def test_neighborhood_post_remains_a_separate_handoff
              turn = FakeTurn.new(action: "neighborhood_post")

              result = Komsiluk.call(turn)

              assert_equal :finish, result.first
              assert_equal({ resolution: "handoff", offered: true }, result.last)
              assert_empty turn.read_calls
            end

            def test_choice_labels_never_print_the_proposal_marker_and_merge_a_shared_name
              with_locales do
                candidates = [
                  { "kind" => "local_area", "text" => "Janja (prijedlog)", "area_kind" => "komsiluk" },
                  { "kind" => "local_area", "text" => "MZ Janja", "area_kind" => "mz" }
                ]

                labels = Komsiluk.choice_labels(candidates, locale: "sr")

                assert_equal ["komšiluk Janja ili mjesna zajednica Janja"], labels
                assert_equal "komšiluk Janja ili mjesna zajednica Janja", Komsiluk.choices_text(candidates, locale: "sr")
                refute_match(/prijedlog/i, Komsiluk.choices_text(candidates, locale: "sr"))
              end
            end

            def test_choice_labels_keep_distinct_areas_apart_and_read_catalog_candidates
              with_locales do
                candidates = [
                  { "slug" => "dvorovi", "kind" => "komsiluk", "label" => "Dvorovi prijedlog" },
                  { "slug" => "gornji-dvorovi", "kind" => "mz", "label" => "Gornji Dvorovi" },
                  { "slug" => "x", "kind" => "street_segment", "label" => "Ulica" },
                  "not a candidate"
                ]

                assert_equal ["Komšiluk Dvorovi", "MZ Gornji Dvorovi"], Komsiluk.choice_labels(candidates, locale: "sr")
                assert_equal "Komšiluk Dvorovi, MZ Gornji Dvorovi", Komsiluk.choices_text(candidates, locale: "sr")
              end
            end

            def test_choices_text_needs_at_least_two_areas_and_transliterates_for_cyrillic
              with_locales do
                assert_nil Komsiluk.choices_text([{ "kind" => "mz", "label" => "Janja" }], locale: "sr")
                assert_nil Komsiluk.choices_text([], locale: "sr")

                candidates = [{ "kind" => "komsiluk", "label" => "Јања (приједлог)" }, { "kind" => "mz", "label" => "МЗ Јања" }]
                assert_equal "комшилук Јања или мјесна заједница Јања", Komsiluk.choices_text(candidates, locale: "sr-Cyrl")
              end
            end

            private

            def with_locales
              old_backend = I18n.backend
              old_locales = I18n.available_locales
              old_enforce = I18n.enforce_available_locales
              I18n.enforce_available_locales = false
              I18n.backend = I18n::Backend::Simple.new
              I18n.available_locales = %w(sr sr-Cyrl bs hr en)
              root = File.expand_path("../../../../../../../config/locales", __dir__)
              I18n.backend.load_translations(*Dir["#{root}/decidim_bih_dialogue*.yml"], *%w(sr sr-Cyrl).map { |locale| "#{root}/#{locale}.yml" })
              yield
            ensure
              I18n.backend = old_backend
              I18n.available_locales = old_locales
              I18n.enforce_available_locales = old_enforce
            end
          end
        end
      end
    end
  end
end

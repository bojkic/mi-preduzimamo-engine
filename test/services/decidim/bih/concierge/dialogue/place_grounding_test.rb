# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Two claims Milica made confidently on 14.09.2026 and could not
        # support, replayed over 648 live turns:
        #
        #   * "pa u bijelini brate, dsnica" (a mistyped Dašnica) came back from
        #     the model as "Bijelina, Dvorovi" and was answered with Dvorovi's
        #     collection days — a different settlement.
        #   * "Znam ulicu iz pitanja" fired six times in one 75-turn slice, five
        #     of them on turns with no street in them at all ("A struja?",
        #     "zasto?", and one whose whole text was "Dvorovi").
        class PlaceGroundingTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 12)
          Message = Data.define(:text, :dialogue_location)
          STREET_WARNING = "street_coverage_not_published_by_source"

          def setup
            @original_load_path = I18n.load_path.dup
            @original_available_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "b" * 64, now: NOW,
                                                     capabilities: %w(public_reads report_guidance registration_handoff))
            @state = StateStore.new.empty_state(@context)
            @reads = []
            @read_result = Contracts::ReadResult.new(status: "empty")
            @runner = ProcedureRunner.new(
              read_port: lambda { |**args|
                @reads << args
                @read_result
              },
              registration_port: ->(**) { Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "/users/sign_up") },
              destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: "/pages/pomoc" }
            )
          end

          def teardown
            I18n.load_path = @original_load_path
            I18n.available_locales = @original_available_locales
            I18n.backend.reload!
          end

          # --- the threshold -------------------------------------------------

          def test_a_place_half_quoted_from_the_citizen_and_half_invented_is_mangled
            assert PlaceGrounding.mangled?("Bijelina, Dvorovi", "pa u bijelini brate, dsnica")
            assert PlaceGrounding.mangled?("Račanska Dvorovi", "Ima li prekida u Račanskoj?")
          end

          def test_a_case_ending_a_script_change_or_one_typo_still_counts_as_the_citizens_own_word
            refute PlaceGrounding.mangled?("Bijeljina Dvorovi", "u Bijeljini, Dvorovi")
            refute PlaceGrounding.mangled?("Vuka Karadžića", "Vuka Karadzica, centar")
            refute PlaceGrounding.mangled?("Dvorovi Janja", "Дворови и Јања")
            refute PlaceGrounding.mangled?("Dašnica Dvorovi", "dsnica i dvorovi")
          end

          def test_a_shared_prefix_alone_does_not_vouch_for_a_different_place
            assert PlaceGrounding.mangled?("Dvorovi Dašnica", "ima li smeca u dvoristu, dsnica")
          end

          def test_qualifiers_and_house_numbers_never_have_to_be_repeated_by_the_citizen
            refute PlaceGrounding.mangled?("Ulica Račanska 14", "Struja, Račanska")
            refute PlaceGrounding.mangled?("mjesna zajednica Dvorovi", "Dvorovi")
          end

          # A value with NONE of the citizen's words is a paraphrase from
          # elsewhere in the conversation, which the dialogue has always
          # allowed. Tightening that is a separate change; this rule must not
          # quietly make it.
          def test_a_value_sharing_no_word_with_the_turn_is_left_alone
            refute PlaceGrounding.mangled?("Janja", "Ima li okupljanja u Dvorovima?")
            refute PlaceGrounding.mangled?("Ulica Primjer 14", "Rupa ispred kuće")
          end

          def test_the_conversations_own_place_slots_witness_a_refinement
            refute PlaceGrounding.mangled?("Janja Dvorovi", "mjesna zajednica", "Janja Dvorovi")
            assert PlaceGrounding.mangled?("Janja Dvorovi", "mjesna zajednica", "Janja")
          end

          # One name cannot be half-quoted, so a single-token value is never
          # refused here — the area matcher decides whether it is a place.
          def test_a_single_name_is_the_area_matchers_business_not_this_rules
            refute PlaceGrounding.mangled?("Dvorovi", "pa u bijelini brate, dsnica")
          end

          # --- what the citizen actually gets --------------------------------

          def test_a_mangled_place_never_reaches_the_reader_and_the_place_question_is_asked_instead
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["waste_district_or_street_segment_required"])
            initial = run_turn("kad dolzi djubretarci kod mene aj reci", topic: "waste", operation: "start",
                                                                         entities: { query: "kad dolazi odvoz" })
            assert_equal I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr"), initial.reply.text
            @reads.clear
            result = run_turn("pa u bijelini brate, dsnica", topic: "waste",
                                                             entities: { query: "kad dolazi odvoz", area_query: "Bijelina, Dvorovi" })

            assert_nil @reads.last[:entities]["area_query"], "a settlement the citizen never named must not select the schedule"
            assert_equal "clarification", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.ask_area_query_again", locale: "sr"), result.reply.text
            assert_includes result.diagnostics.fetch("dropped_entity_keys"), "area_query"
          end

          def test_a_place_the_citizen_did_type_still_answers
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact])
            result = run_turn("Kad se odvozi smeće u Račanskoj?", topic: "waste", operation: "start",
                                                                  entities: { query: "odvoz smeca", street: "Ulica Račanska" })

            assert_equal "answered", result.resolution
            assert_equal "Ulica Račanska", @reads.last[:entities]["street"]
            assert_empty result.diagnostics.fetch("dropped_entity_keys")
          end

          # --- "Znam ulicu iz pitanja" ---------------------------------------

          def test_the_street_caveat_is_said_only_about_a_street_this_turn_supplied
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact], warnings: [STREET_WARNING])
            supplied = run_turn("Ima li prekida vode u Račanskoj?", topic: "water", operation: "start",
                                                                    entities: { query: "prekid vode", street: "Ulica Racanska" })

            assert_includes supplied.reply.text, I18n.t("decidim.bih.dialogue.read_warning_street_not_published", locale: "sr")

            retained = run_turn("Kratko: do koliko sati je najavljen prekid?", topic: "water", entities: { query: "do koliko sati" })

            assert_equal "Ulica Racanska", retained.state.dig("entities", "street"), "the slot is still held; only the CLAIM is dropped"
            assert_equal "Ulica Racanska", @reads.last[:entities]["street"], "the reader still gets the street"
            refute_includes retained.reply.text, I18n.t("decidim.bih.dialogue.read_warning_street_not_published", locale: "sr")
          end

          def test_dropping_the_unsaid_street_claim_leaves_every_other_caveat_standing
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact],
                                                     warnings: [STREET_WARNING, "source_content_not_operator_reviewed"])
            result = run_turn("Ima li prekida vode u Dvorovima?", topic: "water", operation: "start",
                                                                  entities: { query: "prekid vode", area_query: "Dvorovi" })

            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_street_not_published", locale: "sr")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_content_unreviewed", locale: "sr")
            assert_equal "answered", result.resolution
          end

          private

          def run_turn(text, action: "ask_information", topic: "unknown", entities: {}, operation: "continue", locale: "sr") # rubocop:disable Metrics/ParameterLists
            understanding = Contracts::Understanding.parse(action:, topic:, entities:, operation:, locale:,
                                                           needs_clarification: false, secondary: nil)
            result = @runner.call(understanding:, state: @state, context: @context, message: Message.new(text:, dialogue_location: nil))
            @state = result.state
            result
          end

          def fact(id: "notice:1", text: "Reviewed notice")
            {
              "id" => id,
              "kind" => "service_event",
              "text" => text,
              "source_id" => "water_operator",
              "source_url" => "https://operator.example/notice"
            }
          end
        end
      end
    end
  end
end

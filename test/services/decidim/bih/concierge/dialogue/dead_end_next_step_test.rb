# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/topic_menu"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # R3 — A DEAD END MUST CARRY A NEXT STEP.
        #
        # In the 14.09.2026 re-test "Za ovo nemam provjeren podatak" was
        # byte-identical across 49 turns, cited the PDF that supposedly holds
        # the answer, and offered nothing to do. Four of twenty-one
        # conversations ended there. `Kada se odvozi smeće?` refuses;
        # `Kada se odvozi smeće u ulici Filipa Višnjića?` answers — so the
        # refusal was one question away from the answer and never asked it.
        #
        # What must NOT change while it is repaired: the five outcomes a
        # refusal can have (no verified record, unavailable source, unreviewed
        # evidence, unauthorized read, checked zero result) stay five labels
        # with five meanings. Naming where to go is not answering.
        class DeadEndNextStepTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 10, 30)
          Message = Data.define(:text, :dialogue_location)
          SUPPORT = "/pages/pomoc"
          # The shape the host's waste reader returns for a schedule question
          # whose search key was never a place — the reproducing turn, verbatim
          # from production on 14.09.2026.
          WASTE_SOURCE = {
            "id" => "source:waste_schedule",
            "label" => "Komunalac regular waste schedule",
            "url" => "https://www.komunalacbn.com/images/Razno/Program_odvoza_otpada_za_2026.pdf"
          }.freeze

          def setup
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, now: NOW,
                                                     capabilities: %w(public_reads report_guidance registration_handoff))
            @state = StateStore.new.empty_state(@context)
            @reads = []
            @read_result = Contracts::ReadResult.new(status: "empty")
            @runner = ProcedureRunner.new(
              read_port: lambda { |**arguments|
                @reads << arguments
                @read_result.is_a?(Proc) ? @read_result.call(arguments) : @read_result
              },
              registration_port: ->(**) { Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "/users/sign_up") },
              destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: SUPPORT }
            )
          end

          # ---------------------------------------------------------------
          # 1. the question that unlocks the read
          # ---------------------------------------------------------------

          def test_the_reproducing_waste_refusal_asks_for_the_place_instead_of_refusing
            @read_result = waste_miss
            result = waste_turn("Kada se odvozi smeće?")

            assert_equal I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr"), result.reply.text
            refute_includes result.reply.text, refusal
            assert_equal "clarification", result.resolution
            assert_equal "area_query", result.state["pending_slot"]
          end

          # The other half of the same repair: the citizen answers it and the
          # same question now answers. `r4x21` proved this against production.
          def test_the_place_the_question_asked_for_answers_the_same_question
            @read_result = waste_miss
            first = waste_turn("Kada se odvozi smeće?")
            @state = first.state
            @read_result = waste_hit
            second = waste_turn("u ulici Filipa Višnjića", entities: { "area_query" => "Ulica Filipa Višnjića" }, operation: "continue")

            assert_equal "answered", second.resolution
            assert_includes second.reply.text, "Odvoz otpada za „Ulica Filipa Višnjića“: ponedjeljak"
            refute_includes second.reply.text, refusal
          end

          # The loop the re-test recorded (r4c01): `Када се одвози смеће?` then
          # `А за Дашницу конкретно?` returned the byte-identical refusal. A
          # place already supplied is never asked for again.
          def test_a_place_already_supplied_is_never_asked_for_again
            @read_result = waste_miss
            result = waste_turn("A za Dašnicu konkretno?", entities: { "area_query" => "Dašnica" })

            assert_includes result.reply.text, refusal
            assert_equal "unsupported", result.resolution
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr")
          end

          # And a second miss after the question was asked does not re-ask it,
          # whatever the citizen typed: asking twice is the loop, not the repair.
          def test_the_place_question_is_asked_once_per_pending_slot
            @read_result = waste_miss
            first = waste_turn("Kada se odvozi smeće?")
            @state = first.state

            assert_equal "area_query", @state["pending_slot"]

            second = waste_turn("ne znam", operation: "continue")

            refute_equal I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr"), second.reply.text
            assert_includes second.reply.text, refusal
          end

          # A reviewed contact card never needs a neighbourhood. Gating the
          # question on the topic alone asked "Koji je telefon Vodovoda?" for a
          # street; the READ's own warning is what says a place would help.
          def test_a_refusal_without_the_place_warning_is_never_asked_for_a_place
            @read_result = Contracts::ReadResult.new(status: "empty", source: WASTE_SOURCE, warnings: ["no_reviewed_directory_match"])
            result = waste_turn("Da li Komunalac radi subotom?")

            assert_equal "unsupported", result.resolution
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr")
          end

          # ---------------------------------------------------------------
          # 2. the responsible destination
          # ---------------------------------------------------------------

          def test_a_refusal_names_the_publisher_that_holds_the_record
            @read_result = Contracts::ReadResult.new(status: "empty", source: WASTE_SOURCE)
            result = waste_turn("Kada se odvozi smeće u Brčkom?", entities: { "area_query" => "Brčko" })

            step = I18n.t("decidim.bih.dialogue.dead_end_source", locale: "sr", source: "Komunalac regular waste schedule", url: SUPPORT)

            assert_includes result.reply.text, step
          end

          # The host localises a source catalogue key; the refusal is the one
          # reply that is nothing BUT a citation, so it must use that name. The
          # host wraps the key in a "source:" namespace for a read that carries
          # no facts, which is exactly the read a refusal is.
          def test_a_namespaced_source_key_still_finds_its_citizen_facing_name
            with_source_name("source_name_waste_schedule" => "Komunalac, raspored odvoza otpada") do
              @read_result = Contracts::ReadResult.new(status: "empty", source: WASTE_SOURCE)
              result = waste_turn("Kada se odvozi smeće u Brčkom?", entities: { "area_query" => "Brčko" })

              assert_includes result.reply.text, "Izvor: Komunalac, raspored odvoza otpada"
              refute_includes result.reply.text, "Komunalac regular waste schedule"
            end
          end

          # Our own surfaces are not "check with them": a refusal that cites a
          # local path, or cites nothing, is ours to answer.
          def test_a_refusal_with_no_external_publisher_names_the_support_route
            @read_result = Contracts::ReadResult.new(status: "empty", source: { "id" => "platform:volunteer", "url" => "/biceriseno/volontiranje" })
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.dead_end_support", locale: "sr", url: SUPPORT)
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.dead_end_source", locale: "sr", source: "x", url: SUPPORT)
          end

          # THE acceptance, stated once over every refusal shape: no dead end
          # is bare. Each carries a question that unlocks the read, or a named
          # destination and what to do there.
          def test_no_refusal_shape_leaves_without_a_next_step
            shapes = {
              "empty, nothing scoped" => Contracts::ReadResult.new(status: "empty", source: WASTE_SOURCE),
              "empty, no source at all" => Contracts::ReadResult.new(status: "empty"),
              "answered with no facts" => Contracts::ReadResult.new(status: "ok", source: WASTE_SOURCE),
              "stale" => Contracts::ReadResult.new(status: "stale", source: WASTE_SOURCE),
              "unreviewed" => Contracts::ReadResult.new(status: "unreviewed", source: WASTE_SOURCE),
              "unavailable" => Contracts::ReadResult.new(status: "unavailable", warnings: ["read_failed"]),
              "the reproducing waste miss" => waste_miss
            }
            steps = [
              I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr"),
              I18n.t("decidim.bih.dialogue.dead_end_support", locale: "sr", url: SUPPORT),
              SUPPORT
            ]

            shapes.each do |name, read_result|
              @state = StateStore.new.empty_state(@context)
              @read_result = read_result
              text = waste_turn("Kada se odvozi smeće?").reply.text

              assert steps.any? { |step| text.include?(step) },
                     "#{name}: the refusal carries no next step —\n#{text}"
            end
          end

          # ---------------------------------------------------------------
          # 3. what must NOT have moved
          # ---------------------------------------------------------------

          # Naming where to go is not answering, and it is not a hand-off: both
          # would move the turn out of Resolution::UNRESOLVED and back into the
          # success bucket that Task 9b took it out of.
          def test_every_refusal_keeps_the_label_it_had_before_it_gained_a_next_step
            {
              Contracts::ReadResult.new(status: "empty", source: WASTE_SOURCE) => "unsupported",
              Contracts::ReadResult.new(status: "ok", source: WASTE_SOURCE) => "unsupported",
              Contracts::ReadResult.new(status: "stale", source: WASTE_SOURCE) => "source_unavailable",
              Contracts::ReadResult.new(status: "unreviewed", source: WASTE_SOURCE) => "source_unavailable",
              Contracts::ReadResult.new(status: "unavailable", warnings: ["read_failed"]) => "source_unavailable"
            }.each do |read_result, expected|
              @state = StateStore.new.empty_state(@context)
              @read_result = read_result
              result = waste_turn("Kada se odvozi smeće u Brčkom?", entities: { "area_query" => "Brčko" })

              assert_equal expected, result.resolution, "#{read_result.status} changed label"
              refute Resolution.succeeded?(result.resolution), "#{read_result.status} is counted as a success"
            end
          end

          # The place question is the ONE outcome that changes, and it changes
          # to the label that already exists for "we asked and are waiting".
          def test_the_place_question_is_a_clarification_and_nothing_else_moved
            @read_result = waste_miss
            result = waste_turn("Kada se odvozi smeće?")

            assert_equal Resolution::CLARIFICATION, result.resolution
            refute Resolution.unresolved?(result.resolution)
            refute Resolution.source_health?(result.resolution)
          end

          # A scoped zero-result answer is still an ANSWER and never picks up a
          # "next step": nothing is missing, the answer is none.
          def test_a_scoped_zero_result_answer_gains_no_next_step
            @read_result = Contracts::ReadResult.new(
              status: "empty", source: { "id" => "platform:volunteer" },
              coverage: { "access" => "public", "complete_inventory" => false, "requested_area_slugs" => ["dvorovi"],
                          "requested_areas" => [{ "kind" => "mz", "slug" => "dvorovi", "label" => "MZ Dvorovi" }] },
              validity: { "timezone" => "Europe/Sarajevo" }
            )
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal "answered", result.resolution
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.dead_end_support", locale: "sr", url: SUPPORT)
          end

          # The refusal must not spend a second source lookup to say where to go.
          def test_naming_the_destination_costs_no_extra_read
            @read_result = Contracts::ReadResult.new(status: "empty", source: WASTE_SOURCE)
            waste_turn("Kada se odvozi smeće u Brčkom?", entities: { "area_query" => "Brčko" })

            assert_equal 1, @reads.length
          end

          # ---------------------------------------------------------------
          # 4. the top-level menu: chips, and never the same menu twice
          # ---------------------------------------------------------------

          def test_the_top_level_menu_carries_the_four_tappable_openings
            result = run_turn("???", topic: "unknown", entities: {}, action: "help")

            assert_equal I18n.t("decidim.bih.dialogue.clarify", locale: "sr"), result.reply.text
            assert_equal 4, result.reply.quick_replies.length
            assert_includes result.reply.quick_replies.map { |chip| chip[:send] },
                            I18n.t("decidim.bih.dialogue.clarify_chip_service", locale: "sr")
          end

          # Seven re-test turns showed this menu; none of them offered a way
          # out, and the second unresolved turn showed the same menu again.
          def test_the_top_level_menu_is_never_offered_twice
            first = run_turn("???", topic: "unknown", entities: {}, action: "help")
            @state = first.state
            second = run_turn("aaaaaa", topic: "unknown", entities: {}, action: "help")
            @state = second.state
            third = run_turn("qqqqqq", topic: "unknown", entities: {}, action: "help")

            menu = I18n.t("decidim.bih.dialogue.clarify", locale: "sr")

            assert_equal menu, first.reply.text
            assert_equal I18n.t("decidim.bih.dialogue.ask_query", locale: "sr"), second.reply.text
            assert_includes third.reply.text, SUPPORT
            refute_equal menu, second.reply.text
            refute_equal menu, third.reply.text
          end

          # Typed back verbatim on 14.09.2026, "Podaci o gradskoj usluzi" was
          # answered with a MeteoAlarm weather card. A citizen naming one of the
          # four options is answering the menu, so the menu is never repeated at
          # them — they are asked which service.
          def test_naming_the_service_option_asks_which_service_not_the_menu_again
            result = run_turn("Podaci o gradskoj usluzi", topic: "unknown", entities: {}, action: "help")

            assert_equal I18n.t("decidim.bih.dialogue.ask_query", locale: "sr"), result.reply.text
            refute_equal I18n.t("decidim.bih.dialogue.clarify", locale: "sr"), result.reply.text
          end

          def test_the_service_option_is_recognised_in_both_scripts_and_the_menus_own_wording
            ["Podaci o gradskoj usluzi", "podatke o gradskoj usluzi", "Подаци о градској услузи",
             "Gradske usluge", "City service information"].each do |text|
              assert TopicMenu.service_choice_text?(text), "#{text.inspect} is not recognised as the service option"
            end
          end

          # Whole-utterance only: a real question that happens to contain the
          # words is a question, and keeps its normal path.
          def test_a_real_question_is_not_swallowed_by_the_menu_option
            ["Podaci o gradskoj usluzi vodovoda u Dvorovima", "Gdje su podaci o gradskoj usluzi za struju"].each do |text|
              refute TopicMenu.service_choice_text?(text), "#{text.inspect} was swallowed as a menu choice"
            end
          end

          # The ladder's memory is a stored field, so the schema has to accept
          # it: a marker the store drops is a ladder that resets every turn,
          # which is the defect it exists to fix.
          def test_the_menu_step_survives_the_state_store_contract
            first = run_turn("???", topic: "unknown", entities: {}, action: "help")
            stored = StateStore.new.validate(context: @context, state: first.state)

            assert_equal 1, stored.fetch(StateStore::TOPIC_MENU_KEY)
            assert_includes StateStore::STATE_KEYS, StateStore::TOPIC_MENU_KEY
            refute_includes StateStore::TASK_KEYS, StateStore::TOPIC_MENU_KEY
          end

          def test_the_menu_choice_is_registered_as_a_deterministic_route
            require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/deterministic_routes"
            read = DeterministicRoutes.match(Decidim::Bih::Text.fold("Podaci o gradskoj usluzi"), "Podaci o gradskoj usluzi")

            assert_equal "help", read[:action]
            assert_equal "unknown", read[:topic]
          end

          private

          def refusal = I18n.t("decidim.bih.dialogue.no_match", locale: "sr")

          # status "empty" with the host's own account of why: the schedule was
          # searched and the search key was never a place.
          def waste_miss
            Contracts::ReadResult.new(
              status: "empty", source: WASTE_SOURCE,
              warnings: %w(snapshot_not_live_status schedule_exceptions_not_in_snapshot no_reviewed_matching_schedule)
            )
          end

          def waste_hit
            Contracts::ReadResult.new(
              status: "ok", source: WASTE_SOURCE,
              facts: [{
                "id" => "waste_schedule:abc", "kind" => "waste_schedule",
                "text" => "Odvoz otpada za „Ulica Filipa Višnjića“: ponedjeljak",
                "source_id" => "source:waste_schedule", "source_label" => "Komunalac regular waste schedule",
                "source_url" => WASTE_SOURCE.fetch("url")
              }]
            )
          end

          def waste_turn(text, entities: {}, operation: "start")
            run_turn(text, topic: "waste", entities: { "query" => text }.merge(entities), operation:)
          end

          def run_turn(text, topic:, entities:, action: "ask_information", operation: "start", locale: "sr") # rubocop:disable Metrics/ParameterLists
            understanding = Contracts::Understanding.parse(action:, topic:, entities:, operation:, locale:, needs_clarification: false, secondary: nil)
            result = @runner.call(understanding:, state: @state, context: @context, message: Message.new(text:, dialogue_location: nil))
            @state = result.state
            result
          end

          # The host owns its source names; the engine ships none. Added for the
          # duration of one example and removed again.
          def with_source_name(names)
            data = { "decidim" => { "bih" => { "dialogue" => names } } }
            I18n.backend.store_translations(:sr, data)
            yield
          ensure
            I18n.backend.reload!
            I18n.backend.send(:init_translations)
          end
        end
      end
    end
  end
end

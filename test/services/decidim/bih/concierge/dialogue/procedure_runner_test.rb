# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"
# Registration's effective award is read from the one schedule that pays it.
# Production autoloads this; a standalone unit run has to ask for it.
require_relative "../../../../../../app/services/decidim/bih/goodwill/earning_rules"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ProcedureRunnerTest < Minitest::Test
          NOW = Time.utc(2026, 9, 5, 12)
          Message = Data.define(:text, :dialogue_location)

          def setup
            # Global I18n state: capture it so teardown can put it back. Leaving
            # the dialogue locale on the load path made I18n.exists? permanently
            # true for the rest of the process, which silently changed what
            # OTHER tests exercised - FactRendererTest's place-name fallback in
            # particular. A test may borrow global state; it may not keep it.
            @original_load_path = I18n.load_path.dup
            @original_available_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: %w(public_reads report_guidance registration_handoff))
            @state = StateStore.new.empty_state(@context)
            @reads = []
            @handoffs = []
            @read_result = Contracts::ReadResult.new(status: "empty")
            @handoff_result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "/users/sign_up")
            @runner = ProcedureRunner.new(
              read_port: lambda { |**args|
                @reads << args
                @read_result
              },
              registration_port: lambda { |**args|
                @handoffs << args
                @handoff_result
              },
              destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: "/pages/pomoc" }
            )
          end

          def run_turn(text, action: "ask_information", topic: "unknown", entities: {}, operation: "continue", locale: "sr", clarification: false, secondary: nil, location: nil) # rubocop:disable Metrics/ParameterLists
            understanding = Contracts::Understanding.parse(action:, topic:, entities:, operation:, locale:, needs_clarification: clarification, secondary:)
            result = @runner.call(understanding:, state: @state, context: @context, message: Message.new(text:, dialogue_location: location))
            @state = result.state
            result
          end

          def fact(id: "notice:1", text: "Reviewed notice", **extra)
            {
              "id" => id,
              "kind" => "service_event",
              "text" => text,
              "source_id" => "water_operator",
              "source_url" => "https://operator.example/notice"
            }.merge(extra.transform_keys(&:to_s))
          end

          # == Task 4: who owns the current question
          #
          # These recreate the read-only probes of the 14.09 failure trace
          # (docs/operations/milica-current-question-trace-2026-09-14.md §5) as
          # real tests. Each one names the cause it closes.

          # P1 / S1 — the elliptical follow-up. The reader used to be handed the
          # PREVIOUS question plus a retained street, and honestly returned the
          # previous answer.
          def teardown
            I18n.load_path = @original_load_path
            I18n.available_locales = @original_available_locales
            I18n.backend.reload!
          end

          def test_source_missing_destination_does_not_ask_for_the_already_known_origin
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_destination_required"], coverage: {
              "transport_query_entities" => { "stop" => "Bijeljina (NAS)", "date" => "2026-09-16" }
            })
            first = run_turn("Treba mi autobus sutra ujutro iz nove stanice.", topic: "transport", operation: "start")
            assert_equal "area_query", @state["pending_slot"]
            assert_equal I18n.t("decidim.bih.dialogue.ask_transport_destination", locale: :sr), first.reply.text
            second = run_turn("Mislim sutra u odnosu na ovaj razgovor.", topic: "transport", operation: "start", entities: { stop: "ovaj razgovor" })
            assert_equal "Bijeljina (NAS)", @reads.last.fetch(:entities)["stop"]
            assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"]
            assert_equal I18n.t("decidim.bih.dialogue.ask_transport_destination", locale: :sr), second.reply.text
          end

          def test_source_echo_of_a_facet_word_cannot_overwrite_retained_destination
            @state = StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => "transport",
              "entities" => { "stop" => "Batković", "area_query" => "Dvorovi", "via_stop" => "centar" },
              "entity_provenance" => { "stop" => "citizen", "area_query" => "citizen", "via_stop" => "citizen" })
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_via_required"], coverage: {
              "transport_query_entities" => { "stop" => "smjera", "area_query" => "prelazak" }
            })
            answer = run_turn("Koliko vremena ostaje za prelazak do drugog stajališta?", topic: "transport")
            assert_equal "Dvorovi", @state.fetch("entities")["area_query"]
            assert_equal "Batković", @state.fetch("entities")["stop"]
            assert_includes answer.reply.text, "Dvorovi"
            refute_includes answer.reply.text, "prelazak"
          end

          def test_transport_facet_cannot_replace_real_endpoints_with_common_nouns_or_add_secondary_task
            [
              ["Koliko vremena ostaje za prelazak do drugog stajališta?", { area_query: "prelazak", stop: "drugog stajališta" }],
              ["Разликује ли се од смјера ка споменику?", { stop: "smjera" }],
              ["Odvoji gradske podatke od međugradskog reda.", { stop: "medjugradskog reda" }],
              ["Gdje tačno presjedam i koliko čekam drugi autobus?", { area_query: "drugi autobus" }],
              ["Ne mijenjaj odredište u centar.", { area_query: "centar" }]
            ].each do |text, proposed|
              @state = StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => "transport",
                "entities" => { "stop" => "Batković", "area_query" => "Dvorovi", "via_stop" => "Bijeljina NAS", "date" => "2026-09-16" },
                "entity_provenance" => { "stop" => "citizen", "area_query" => "citizen", "via_stop" => "citizen", "date" => "citizen" })
              run_turn(text, topic: "transport", operation: "start", entities: proposed, secondary: { action: "registration", topic: "account" })
              asked = @reads.last.fetch(:entities)
              assert_equal "Batković", asked["stop"], text
              assert_equal "Dvorovi", asked["area_query"], text
              assert_equal "Bijeljina NAS", asked["via_stop"], text
              assert_equal "2026-09-16", asked["date"], text
              assert_nil @state["suspended_task"], text
            end
          end

          def test_common_transport_nouns_never_enter_state_as_model_places
            ["smjera", "prelazak", "medjugradskog reda", "dvorova moze veza"].each do |place|
              @state = StateStore.new.empty_state(@context)
              run_turn("Autobus do Dvorova", topic: "transport", operation: "start", entities: { stop: place, area_query: place })
              refute @reads.last.fetch(:entities).key?("stop"), place
              refute @reads.last.fetch(:entities).key?("area_query"), place
            end
          end

          def test_model_cannot_invent_via_stop_from_a_direct_journey_destination
            run_turn("Idem od Dvorovi CSP do Bijeljina spomenik u srijedu poslije 06:00", topic: "transport", operation: "start",
                     entities: { stop: "Dvorovi CSP", area_query: "Bijeljina spomenik", via_stop: "Bijeljina spomenik" })
            refute @reads.last.fetch(:entities).key?("via_stop")
            refute @state.fetch("entities").key?("via_stop")
            assert_equal "Bijeljina spomenik", @reads.last.fetch(:entities).fetch("area_query")
          end

          def test_destination_clarification_cannot_manufacture_an_origin_or_reset_a_valid_origin
            [nil, "Bijeljina (NAS)"].each do |origin|
              ["Mislim na školu u Janji.", "Мислим на школу у Јањи.", "Do škole u Janji"].each do |question|
                @state = StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => "transport",
                  "entities" => { "area_query" => "škole" }, "entity_provenance" => { "area_query" => "citizen" }, "pending_slot" => "stop")
                if origin
                  @state["entities"]["stop"] = origin
                  @state["entity_provenance"]["stop"] = "citizen"
                end
                run_turn(question, topic: "transport", operation: "start", entities: { stop: "škola u Janji", area_query: "Janja" })
                assert_equal [origin], [@reads.last.fetch(:entities)["stop"]], question
                assert_equal [origin], [@state.fetch("entities")["stop"]], question
                assert_equal question, @reads.last.fetch(:entities).fetch("query")
              end
            end
          end

          def test_direct_only_constraint_is_source_retained_and_source_released
            @read_result = Contracts::ReadResult.new(status: "empty")
            run_turn("Do Janje", topic: "transport", operation: "start", entities: { transfer_mode: "direct" })
            refute @state.fetch("entities").key?("transfer_mode"), "model flags are not citizen constraints"
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
              "transport_query_entities" => { "transfer_mode" => "direct" }
            })
            run_turn("Bez presjedanja", topic: "transport")
            assert_equal "direct", @state.fetch("entities").fetch("transfer_mode")
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: { "transport_query_invalidated_entities" => ["transfer_mode"] })
            run_turn("Može i presjedanje", topic: "transport")
            refute @state.fetch("entities").key?("transfer_mode")
          end

          def test_read_only_followup_keeps_water_query_and_asks_only_for_missing_area
            run_turn("Има ли данас прекида воде?", topic: "water", operation: "start", locale: "sr-Cyrl")
            result = run_turn("Не желим да направим пријаву.", topic: "water", locale: "sr-Cyrl")
            assert_equal "clarification", result.resolution
            assert_equal "ask_information", @state["active_task"]
            assert_equal "area_query", @state["pending_slot"]
            assert_includes result.reply.text, "не подносим пријаву"
            assert_empty @reads
            assert_empty @handoffs
          end

          def test_waste_missing_detail_followup_asks_for_place_instead_of_repeating_directory
            run_turn("Gdje je odvoz smeća za moju ulicu?", topic: "waste", operation: "start")
            count = @reads.length
            result = run_turn("Odgovor nije koristan, reci šta ti nedostaje da provjeriš.", topic: "waste")
            assert_equal "clarification", result.resolution
            assert_equal "area_query", @state["pending_slot"]
            assert_includes result.reply.text, "naselju ili ulici"
            assert_equal count, @reads.length
          end

          def test_transport_evidence_constraint_preserves_endpoints_and_genuine_ambiguity
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_ambiguous"],
              candidates: [{ "text" => "Janja (centar)" }, { "text" => "Janja (škola)" }])
            run_turn("Iz Janje do bolnice", topic: "transport", operation: "start", entities: { area_query: "bolnica" })
            result = run_turn("Nemoj izmisliti noćnu autobusku liniju.", topic: "transport")
            assert_equal "clarification", result.resolution
            assert_equal "bolnica", @state.fetch("entities").fetch("area_query")
            assert_equal "stop", @state["pending_slot"]
            assert_includes result.reply.text, "objavljenom redu vožnje"
            assert_includes result.reply.text, "Janja (škola)"
          end

          def test_source_validated_via_removal_stays_removed_on_third_turn
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
              "transport_query_entities" => { "stop" => "Dvorovi", "area_query" => "Janja škola", "via_stop" => "centar" }
            })
            run_turn("Iz Dvorova preko centra do škole u Janji", topic: "transport", operation: "start")
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: { "transport_query_invalidated_entities" => ["via_stop"] })
            run_turn("Bez centra, samo do škole u Janji", topic: "transport")
            refute @state.fetch("entities").key?("via_stop")
            @read_result = Contracts::ReadResult.new(status: "empty")
            run_turn("U subotu", topic: "transport")
            refute @reads.last.fetch(:entities).key?("via_stop")
            assert_equal "Janja škola", @reads.last.fetch(:entities).fetch("area_query")
          end

          def test_unmatched_named_origin_gets_specific_recovery_and_bounded_escalation
            @read_result = Contracts::ReadResult.new(status: "empty", warnings: ["origin_not_in_reviewed_timetable"],
              coverage: { "transport_query_entities" => { "stop" => "Nepoznati muzej" } })
            first = run_turn("Iz Nepoznatog muzeja do Janje", topic: "transport", operation: "start")
            assert_equal "clarification", first.resolution
            assert_includes first.reply.text, "Nepoznati muzej"
            run_turn("Mislim na taj muzej", topic: "transport")
            third = run_turn("Ne znam više", topic: "transport")
            assert_equal "handoff", third.resolution
          end

          def test_completed_public_lookup_is_retained_without_unrelated_saved_task_copy
            run_turn("Koliko košta parking?", topic: "parking", operation: "start")
            next_answer = run_turn("Kako da se registrujem?", action: "registration", topic: "account", operation: "switch")
            assert_equal "parking", @state.dig("suspended_task", "topic")
            refute_includes next_answer.reply.text, I18n.t("decidim.bih.dialogue.resume_offer", locale: "sr")
            resumed = run_turn("nastavi", action: "help", clarification: true)
            assert_equal "parking", @state["topic"]
            refute_equal "cancelled", resumed.resolution
          end

          def test_unrecognized_supplied_area_is_acknowledged_before_requesting_a_discriminator
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_not_found"])
            first = run_turn("Voda u Nepoznatom naselju", topic: "water", operation: "start", entities: { area_query: "Nepoznato naselje" })
            assert_includes first.reply.text, "Nepoznato naselje"
            assert_includes first.reply.text, "ulicu"
            assert_equal "area_query", @state["pending_slot"]
          end

          def test_repeated_transport_ambiguity_requests_a_verified_choice_and_stays_bounded
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_ambiguous"],
                                                     candidates: [{ "text" => "Janja (centar)" }, { "text" => "Janja (škola)" }])
            run_turn("Iz Janje do bolnice", topic: "transport", operation: "start")
            again = run_turn("Gdje da uđem?", topic: "transport")
            assert_includes again.reply.text, "Janja (škola)"
            assert_includes again.reply.text, "Izaberi"
            assert_equal "clarification", again.resolution
            limit = run_turn("Još ne znam", topic: "transport")
            assert_equal "handoff", limit.resolution
          end

          def test_corrected_public_read_slot_is_used_even_if_model_asks_to_clarify
            run_turn("Struja u Dvorovima", topic: "electricity", operation: "start", entities: { area_query: "Dvorovi" })
            result = run_turn("Ne Dvorovi, Ledinci", topic: "electricity", operation: "correct",
                              entities: { area_query: "Ledinci" }, clarification: true)
            assert_equal "Ledinci", @reads.last.fetch(:entities).fetch("area_query")
            assert_equal 2, @reads.size
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.repair_clarify", locale: "sr")
          end

          def test_host_resolved_via_stop_survives_state_validation_and_next_read
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
              "transport_query_entities" => { "stop" => "Dvorovi", "area_query" => "Janja škola", "via_stop" => "centar" }
            })
            run_turn("Iz Dvorova preko centra do škole u Janji", topic: "transport", operation: "start")
            assert_equal "centar", @state.fetch("entities").fetch("via_stop")
            @read_result = Contracts::ReadResult.new(status: "empty")
            run_turn("U subotu", topic: "transport")
            assert_equal "centar", @reads.last.fetch(:entities).fetch("via_stop")
            assert_equal "Janja škola", @reads.last.fetch(:entities).fetch("area_query")
          end

          def test_an_elliptical_follow_up_replaces_the_retained_question_not_the_place
            run_turn("Kad se kupi smeće u Ulici Filipa Višnjića?", topic: "waste", operation: "start",
                                                                   entities: { query: "kad se kupi smece", street: "Ulica Filipa Visnjica" })
            run_turn("Da li Komunalac radi subotom?", topic: "waste", entities: {})

            assert_equal "Da li Komunalac radi subotom?", @reads.last[:entities]["query"]
            assert_equal "Ulica Filipa Visnjica", @reads.last[:entities]["street"], "a compatible place slot is retained"
          end

          # P7 — the model is shown the retained entity VALUES, so it can hand a
          # retained street back as if the citizen had just said it. Stamping
          # that "citizen" is what makes supplied and retained indistinguishable.
          def test_a_retained_slot_the_model_echoes_back_is_not_counted_as_supplied
            first = run_turn("Ima li prekida vode u Ulici Račanskoj?", topic: "water", operation: "start",
                                                                       entities: { query: "prekid vode", street: "Ulica Racanska" })
            assert_equal %w(query street), first.diagnostics.fetch("supplied_entity_keys")

            second = run_turn("A koliko to košta?", topic: "water", entities: { street: "Ulica Racanska" })

            assert_empty second.diagnostics.fetch("supplied_entity_keys"), "an echoed street is not a new fact"
            assert_equal %w(query street), second.diagnostics.fetch("retained_entity_keys")
            assert_equal "A koliko to košta?", @reads.last[:entities]["query"]
          end

          # P4 / RC-4 — for water/electricity/heating the model's query replaced
          # the retained one, and on an entity-free turn the model's query is "".
          def test_an_entity_free_utility_follow_up_never_reads_with_an_empty_query
            run_turn("Ima li obustave vode u Dvorovima?", topic: "water", operation: "start",
                                                          entities: { query: "obustava vode", area_query: "Dvorovi" })
            run_turn("A koji je njihov broj telefona?", topic: "water", entities: {})

            refute_empty @reads.last[:entities]["query"].to_s
            assert_equal "A koji je njihov broj telefona?", @reads.last[:entities]["query"]
          end

          # P3 / S5 / RC-3 — resolve_area reads area_slug/area_query and nothing
          # else, so a retained area silently outranked every corrected street.
          def test_a_street_correction_leaves_no_retained_area_behind_on_a_read
            run_turn("Ima li obustave vode?", topic: "water", operation: "start",
                                              entities: { query: "obustava vode", area_query: "mjesna zajednica Centar" })
            result = run_turn("Ispravka: treba mi za Baje Pivljanina.", topic: "water", operation: "correct",
                                                                        entities: { street: "Baje Pivljanina" })

            assert_nil @reads.last[:entities]["area_query"], "the stale area cannot outlive the correction"
            assert_equal "Baje Pivljanina", @reads.last[:entities]["street"]
            assert_equal ["area_query"], result.diagnostics.fetch("dropped_entity_keys")
          end

          # S14 / RC-9 — any entity at all used to nil the opaque draft, so a
          # confirmation the model decorated with one slot minted a new
          # reference and the chip the citizen was looking at went stale.
          def test_a_confirmation_decorated_with_an_unrelated_slot_keeps_the_draft
            draft = { "reference" => "c" * 16, "revision" => 2, "expires_at" => NOW.to_f + 120 }
            @state = @state.merge("active_task" => "report_problem", "topic" => "waste", "draft" => draft,
                                  "entities" => { "description" => "Rupa na putu", "area_query" => "Dvorovi" },
                                  "entity_provenance" => { "description" => "citizen", "area_query" => "citizen" })

            result = run_turn("da, hoću", action: "report_problem", topic: "waste", entities: { time_expression: "danas" })

            assert_equal draft, @state["draft"]
            refute result.diagnostics.fetch("draft_replaced")
          end

          def test_a_corrected_place_still_replaces_the_draft
            draft = { "reference" => "c" * 16, "revision" => 2, "expires_at" => NOW.to_f + 120 }
            @state = @state.merge("active_task" => "report_problem", "topic" => "waste", "draft" => draft,
                                  "entities" => { "description" => "Rupa na putu", "area_query" => "Dvorovi" },
                                  "entity_provenance" => { "description" => "citizen", "area_query" => "citizen" })

            result = run_turn("Ne Dvorovi, Janja", action: "report_problem", topic: "waste", operation: "correct",
                                                   entities: { area_query: "Janja" })

            assert_nil @state["draft"]
            assert result.diagnostics.fetch("draft_replaced")
          end

          # P6 / RC-8 — a refused transition burned a clarification AND a CAS
          # version while reporting transition "none", which is also what a
          # guarded reply and the empty-understanding fallback report.
          def test_a_refused_transition_is_named_and_costs_no_clarification
            run_turn("Ima li obustave vode u Dvorovima?", topic: "water", operation: "start",
                                                          entities: { query: "obustava vode", area_query: "Dvorovi" })
            @state = @state.merge("pending_slot" => "area_query", "clarification_count" => 2)

            result = run_turn("Nešto sasvim drugo", action: "report_problem", topic: "roads", operation: "continue")

            assert_equal "clarification", result.resolution
            assert_equal "refused", result.diagnostics.fetch("transition")
            assert_equal 2, @state["clarification_count"], "our refusal is not the citizen's failed attempt"
          end

          # P8 / S11 / RC-6 — "vrati se" was in RESUME_COMMANDS; the sentence
          # containing it was not, so the turn started an EMPTY new task while
          # the suspended one still held the citizen's street.
          def test_a_sentence_form_return_request_restores_the_task_and_answers_its_question
            suspended = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "ask_information", "topic" => "waste",
              "entities" => { "query" => "odvoz smeća", "street" => "Svetog Save" },
              "entity_provenance" => { "query" => "citizen", "street" => "citizen" }
            )
            @state = @state.merge("active_task" => "ask_information", "topic" => "city_service",
                                  "entities" => { "query" => "rodni list" }, "entity_provenance" => { "query" => "citizen" },
                                  "suspended_task" => suspended)

            result = run_turn("Vrati se na ono za smeće, koji dan si rekla?", action: "help", topic: "unknown", operation: "clarify", clarification: true)

            assert_equal "waste", @state["topic"]
            assert_equal "Svetog Save", @state.dig("entities", "street")
            assert_equal "koji dan si rekla?", @reads.last[:entities]["query"]
            assert_equal "resume", result.diagnostics.fetch("transition")
            assert_nil @state["suspended_task"]
          end

          # S7 / RC-5 — Turn#cancellation? executed ANY model-asserted cancel
          # with no deterministic corroboration, so one misread courtesy wiped
          # a task holding the citizen's own slots.
          def test_an_uncorroborated_model_cancel_cannot_wipe_a_task_holding_citizen_slots
            @state = @state.merge("active_task" => "report_problem", "topic" => "waste",
                                  "entities" => { "description" => "Rupa na putu" },
                                  "entity_provenance" => { "description" => "citizen" })

            result = run_turn("Dobro, hvala.", action: "cancel", topic: "unknown", operation: "cancel")

            assert_equal "clarification", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.cancel_confirm", locale: :sr)
            assert_equal "report_problem", @state["active_task"]
            assert_equal "Rupa na putu", @state.dig("entities", "description")
            assert_equal 0, @state["clarification_count"]
          end

          def test_a_corroborated_cancel_still_cancels
            @state = @state.merge("active_task" => "report_problem", "topic" => "waste",
                                  "entities" => { "description" => "Rupa na putu" },
                                  "entity_provenance" => { "description" => "citizen" })

            result = run_turn("Odustani", action: "cancel", topic: "unknown", operation: "cancel")

            assert_equal "cancelled", result.resolution
            assert_empty @state.fetch("entities")
          end

          # "kraće" had no representation anywhere. It is a presentation
          # operation on the answer already given: same task, same question,
          # no new read family and no cancellation.
          def test_a_brevity_request_keeps_the_question_and_steps_the_level_down
            facts = (1..6).map { |index| fact(id: "reward:#{index}", text: "Nagrada #{index}: opis. Cijena u bodovima: #{index * 10}.") }
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: NOW - 60, facts:)
            full = run_turn("Koje nagrade mogu dobiti?", topic: "rewards", operation: "start", entities: { query: "nagrade" })
            # A turn that asked for no particular presentation stores none: the
            # absent key READS BACK as the default, so an ordinary turn does not
            # churn the CAS-versioned state with a redundant value.
            assert_nil @state[StateStore::PRESENTATION_LEVEL_KEY]

            short = run_turn("Kraće molim.", topic: "rewards", entities: {})

            assert_equal "short", @state[StateStore::PRESENTATION_LEVEL_KEY]
            assert_equal "rewards", @state["topic"], "a brevity request is not a new task"
            assert_equal "nagrade", @reads.last[:entities]["query"], "and not a new question either"
            assert_operator short.reply.text.length, :<, full.reply.text.length

            shorter = run_turn("Još kraće.", topic: "rewards", entities: {})
            assert_equal "brief", @state[StateStore::PRESENTATION_LEVEL_KEY]
            assert_operator shorter.reply.text.length, :<=, short.reply.text.length
          end

          def test_brevity_rereads_the_valid_public_anchor_when_no_query_entity_was_retained
            text = "Налазим се код болнице у Бијељини. Како до најближе аутобуске станице?"
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(text: "Hospital stop: approximate position")])
            first = run_turn(text, topic: "transport", operation: "start", locale: "sr-Cyrl")
            assert_equal text, first.state.dig(AnswerContext::KEY, "anchor")
            assert_nil first.state.dig("entities", "query")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(text: "Fresh hospital stop result")])
            second = run_turn("Молим те кратко, читам на телефону.", topic: "transport", locale: "sr-Cyrl")
            assert_equal 2, @reads.length, "presentation makes a fresh authorized read"
            assert_equal text, @reads.last.fetch(:entities)["query"]
            assert_equal "answered", second.resolution
            assert_equal "short", second.state[StateStore::PRESENTATION_LEVEL_KEY]
            assert_equal text, second.state.dig(AnswerContext::KEY, "anchor")
          end

          def test_brevity_uses_the_answered_question_when_a_model_query_omitted_its_origin
            text = "Налазим се код болнице у Бијељини. Како до најближе аутобуске станице?"
            ["Najbliže autobusko stajalište", "Kako do autobuske stanice?", "Bolnica"].each do |query|
              @state = StateStore.new.empty_state(@context)
              @reads.clear
              @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(text: "Hospital stop: approximate position")])
              first = run_turn(text, topic: "transport", operation: "start", locale: "sr-Cyrl", entities: { query: })
              assert_equal text, first.state.dig(AnswerContext::KEY, "anchor")
              assert_equal query, first.state.dig("entities", "query")
              @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(text: "Fresh hospital stop result")])
              second = run_turn("Молим те кратко, читам на телефону.", topic: "transport", locale: "sr-Cyrl")
              assert_equal text, @reads.last.fetch(:entities)["query"], "re-read the question actually answered"
              assert_equal 2, @reads.length
              assert_equal "answered", second.resolution
              assert_equal "short", second.state[StateStore::PRESENTATION_LEVEL_KEY]
              assert_equal text, second.state.dig(AnswerContext::KEY, "anchor")
            end
          end

          def test_brevity_does_not_replay_old_facts_when_the_fresh_reader_is_unavailable
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(text: "Old hospital stop result")])
            run_turn("Kako do stajališta kod bolnice?", topic: "transport", operation: "start")
            @read_result = Contracts::ReadResult.new(status: "unavailable", warnings: ["source_unavailable"])
            result = run_turn("Kraće molim.", topic: "transport")
            assert_equal "Kako do stajališta kod bolnice?", @reads.last.fetch(:entities)["query"]
            assert_equal "source_unavailable", result.resolution
            assert_empty result.fact_ids
            refute_includes result.reply.text, "Old hospital stop result"
          end

          def test_presentation_cannot_reuse_expired_mismatched_or_private_answer_anchors
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact])
            run_turn("Kako do stajališta kod bolnice?", topic: "transport", operation: "start")
            original = @state
            [
              { "expires_at" => NOW.to_f },
              { "topic" => "water", "subject" => "ask_information:water" },
              { "subject" => "ask_information:water" },
              { "topic" => "account", "subject" => "ask_information:account", "anchor" => "Moji privatni podaci" }
            ].each do |changes|
              @state = original.merge(AnswerContext::KEY => original.fetch(AnswerContext::KEY).merge(changes))
              run_turn("Kraće molim.", topic: "transport")
              assert_nil @reads.last.fetch(:entities)["query"], changes.inspect
            end
          end

          # b2c19 t2 — "Koji je tačan datum i sat roka?" carries no slot and
          # names no subject, so the model proposed a switch; the switch reset
          # the entity bag and the retained question was answered instead.
          def test_an_entity_free_back_reference_refines_the_task_instead_of_switching_it
            run_turn("Do kada mogu steći pravo na pozivnicu za 17. septembar?", topic: "launch", operation: "start",
                                                                                entities: { query: "do kada pravo na pozivnicu" })
            result = run_turn("Koji je tačan datum i sat roka?", topic: "public_calls", operation: "switch", entities: {})

            assert_equal "launch", @state["topic"], "an elliptical refinement is not a topic switch"
            assert_equal "Koji je tačan datum i sat roka?", @reads.last[:entities]["query"]
            assert_equal "continue", result.diagnostics.fetch("transition")
            assert_nil @state["suspended_task"], "and it does not suspend anything either"
          end

          def test_a_named_new_subject_still_switches
            run_turn("Kada se odvozi smeće u Dvorovima?", topic: "waste", operation: "start",
                                                          entities: { query: "odvoz smeća", area_query: "Dvorovi" })
            result = run_turn("A ima li prekida struje?", topic: "electricity", operation: "switch",
                                                          entities: { query: "prekid struje" })

            assert_equal "electricity", @state["topic"]
            assert_equal "switch", result.diagnostics.fetch("transition")
          end

          # There is no reply cache: an identical question genuinely re-runs the
          # read. Repeating a valid reminder must therefore stay valid — the
          # repair must not turn a legitimate repeat into a "you already asked".
          def test_an_identical_repeated_question_is_answered_again_with_the_same_inputs
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: NOW - 60,
                                                     facts: [fact(id: "waste:dvorovi", text: "Smeće se odvozi utorkom i petkom.")])
            first = run_turn("Kada se odvozi smeće u Dvorovima?", topic: "waste", operation: "start",
                                                                  entities: { query: "odvoz smeća", area_query: "Dvorovi" })
            second = run_turn("Kada se odvozi smeće u Dvorovima?", topic: "waste",
                                                                   entities: { query: "odvoz smeća", area_query: "Dvorovi" })

            assert_equal "answered", second.resolution
            assert_equal first.reply.text, second.reply.text
            assert_equal 2, @reads.length, "each turn re-runs the read; nothing is replayed from a cache"
            assert_equal @reads.first[:entities], @reads.last[:entities]
          end

          # Acceptance: each repaired sequence must give the same answer asked
          # cold as it does mid-conversation. A repair that only works because
          # of what is retained is not a repair.
          def test_each_repaired_question_answers_the_same_cold_as_it_does_in_context
            [
              ["Da li Komunalac radi subotom?", "waste", { query: "kad se kupi smece", street: "Ulica Filipa Visnjica" }],
              ["A koji je njihov broj telefona?", "water", { query: "obustava vode", area_query: "Dvorovi" }],
              ["Koji je tačan datum i sat roka?", "launch", { query: "do kada pravo na pozivnicu" }]
            ].each do |question, topic, opening|
              @state = StateStore.new.empty_state(@context)
              @reads.clear
              run_turn("Prvo pitanje", topic:, operation: "start", entities: opening)
              in_context = run_turn(question, topic:, entities: {})
              context_read = @reads.last[:entities]["query"]

              @state = StateStore.new.empty_state(@context)
              @reads.clear
              cold = run_turn(question, topic:, operation: "start", entities: {})

              assert_equal question, context_read, question
              assert_equal question, @reads.last[:entities]["query"], question
              assert_equal cold.resolution, in_context.resolution, question
              assert_equal cold.reply.text, in_context.reply.text, question
            end
          end

          # == Task 7: the reply a citizen actually receives

          # The measured defect: a nine-item catalogue rendered 1.422
          # characters with the same URL printed eight times and no price.
          def test_a_catalogue_read_is_cited_once_and_stays_inside_the_budget
            facts = (1..8).map do |index|
              fact(id: "reward:#{index}", text: "MI! nagrada #{index}: opis nagrade. Cijena u bodovima: #{index * 10}.",
                   source_label: "MI PRE(D)UZIMAMO!", source_url: "https://mi.example/nagrade")
            end
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: NOW - 60, facts:)
            result = run_turn("Koje nagrade mogu dobiti?", topic: "rewards", operation: "start", entities: { query: "nagrade" })
            text = result.reply.text

            assert_equal "answered", result.resolution
            assert_equal 1, text.scan("https://mi.example/nagrade").length, "one citation for the whole catalogue"
            assert_equal 1, text.scan(I18n.t("decidim.bih.dialogue.source", locale: :sr, source: "MI PRE(D)UZIMAMO!")).length
            assert_includes text, "Cijena u bodovima: 10."
            assert_includes text, I18n.t("decidim.bih.dialogue.more_items", locale: :sr, shown: 3, total: 8)
            assert_operator text.length, :<, 900, text
          end

          # "Samo naziv i cijena" is a presentation request about the same
          # question, not a new one — and the price is never what goes.
          def test_a_brevity_request_shortens_the_same_answer_without_losing_the_price
            facts = (1..5).map do |index|
              fact(id: "reward:#{index}", text: "MI! nagrada #{index}: opis. Cijena u bodovima: #{index * 10}.",
                   source_label: "Katalog", source_url: "https://mi.example/nagrade")
            end
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: NOW - 60, facts:)
            full = run_turn("Koje nagrade mogu dobiti?", topic: "rewards", operation: "start", entities: { query: "nagrade" })
            @state = StateStore.new.empty_state(@context)
            short = run_turn("Samo naziv i cijena u bodovima, molim.", topic: "rewards", operation: "start", entities: { query: "nagrade" })

            assert_operator short.reply.text.length, :<, full.reply.text.length
            assert_includes short.reply.text, "Cijena u bodovima: 10."
            assert_includes short.reply.text, "https://mi.example/nagrade"
            assert_includes short.reply.text, I18n.t("decidim.bih.dialogue.more_items", locale: :sr, shown: 1, total: 5)
          end

          # A source that publishes a truncated teaser and then the full
          # notice must not make the reply say the same sentence twice.
          def test_a_truncated_teaser_restated_by_its_own_notice_is_printed_once
            teaser = "Dana 14. septembra 2026. godine, zbog otklanjanja kvarova na vodovodnoj mreži i priključenja n"
            full = "Dana 14. septembra 2026. godine, zbog otklanjanja kvarova na vodovodnoj mreži i priključenja novog korisnika, " \
                   "mogući su prekidi vodosnabdijevanja u ulici Baje Pivljanina."
            @read_result = Contracts::ReadResult.new(status: "ok", checked_at: NOW - 60,
                                                     facts: [fact(text: "Prekid vodosnabdijevanja: #{teaser}: #{full}")])
            entities = { area_query: "Dvorovi", query: "prekid vode" }
            result = run_turn("Ima li danas prekida vode u Dvorovima?", topic: "water", operation: "start", entities:)

            assert_equal 1, result.reply.text.scan("zbog otklanjanja kvarova").length
            assert_includes result.reply.text, "u ulici Baje Pivljanina."
          end

          def test_reporting_collects_only_missing_fields_and_preserves_report_intent_through_correction
            first = run_turn("Smeće nije odvezeno, hoću prijaviti", action: "report_problem", topic: "waste", operation: "start", entities: { description: "Smeće nije odvezeno" })
            assert_equal "clarification", first.resolution
            assert_equal "area_query", @state["pending_slot"]
            second = run_turn("U Dvorovima", action: "report_problem", entities: { area_query: "Dvorovi" })
            assert_equal "handoff", second.resolution
            assert_nil second.reply.report
            refute second.handoff_completed
            assert_includes second.reply.text, "Ništa još nije poslano"
            third = run_turn("Ne ta ulica, Svetog Save", action: "report_problem", operation: "correct", entities: { street: "Svetog Save" })
            assert_equal "report_problem", @state["active_task"]
            assert_equal "waste", @state["topic"]
            assert_equal "Svetog Save", @state["entities"]["street"]
            assert_equal "corrected", @state["entity_provenance"]["street"]
            assert_equal "handoff", third.resolution
            assert_empty @reads # A named place alone cannot invent a radius/GPS duplicate search.
          end

          def test_transport_origin_warning_reasks_duplicated_stop_and_preserves_destination
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_required"])
            first = run_turn("Autobus do Dvorova", topic: "transport", operation: "start", entities: { stop: "Dvorovi", area_query: "Dvorovi" })

            assert_equal "clarification", first.resolution
            assert_equal "stop", @state["pending_slot"]
            assert_includes first.reply.text, I18n.t("decidim.bih.dialogue.ask_stop", locale: "sr")
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
              "transport_query_entities" => { "stop" => "Bijeljina (NAS)" }
            })
            second = run_turn("Od autobuske stanice u Bijeljini", topic: "transport", entities: { stop: "Bijeljina (NAS)" })

            # The fixture read carries no facts, so the turn ends with the "no verified
            # data" refusal. That is "unsupported", not "answered" (Task 9b).
            assert_equal "unsupported", second.resolution
            # The unspoken acronym is resolved by the host source, not trusted
            # merely because the model proposed it while a choice was pending.
            assert_equal "Od autobuske stanice u Bijeljini", @reads.last.fetch(:entities).fetch("query")
            assert_equal "Bijeljina (NAS)", @state.fetch("entities").fetch("stop")
            assert_equal "Dvorovi", @reads.last.fetch(:entities).fetch("area_query")
            assert_nil @state["pending_slot"]
          end

          # Scripted understanding variants exercise the actual runner boundary;
          # these are not a recording of a provider payload.
          def test_unreviewed_transport_day_is_not_described_as_a_temporary_outage
            [%w(unavailable unsupported_service_day), %w(unreviewed service_calendar_requires_review)].each do |status, warning|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status:, warnings: [warning], coverage: {
                                                         "transport_query_entities" => { "stop" => "NAS", "area_query" => "Intergaj", "date" => "2026-11-21" }
                                                       })
              result = run_turn("Od NAS do Intergaja na praznik 21.11.2026.", topic: "transport", operation: "start")
              assert_equal "source_unavailable", result.resolution
              assert_includes result.reply.text, "potvrđen red vožnje"
              assert_includes result.reply.text, "nije potvrda da autobusi ne voze"
              refute_match(/minuta|trenutno nije dostupan/, result.reply.text)
              assert_equal "2026-11-21", result.state.fetch("entities").fetch("date")
              assert_nil result.reply.report
              refute result.handoff_completed
            end
            @read_result = Contracts::ReadResult.new(status: "unavailable", warnings: ["deadline_exceeded"])
            result = run_turn("Od NAS do Intergaja", topic: "transport", operation: "start")
            refute_includes result.reply.text, "potvrđen red vožnje"
          end

          def test_transport_local_date_followups_keep_the_literal_reader_question
            [
              ["A u nedjelju 20.9.2026. u isto vrijeme?", "2026-09-20", "08:00"],
              ["A za vrijeme školskog raspusta, 5.1.2027. poslije 06:00?", "2027-01-05", "06:00"],
              ["А у недјељу 20.9.2026. у исто вријеме?", "2026-09-20", "08:00"]
            ].each do |text, date, clock|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
                                                         "transport_query_entities" => {
                                                           "stop" => "NAS", "area_query" => "Intergaj", "date" => "2026-09-19", "time_expression" => "08:00"
                                                         }
                                                       })
              run_turn("Od NAS do Intergaja u subotu", topic: "transport", operation: "start")
              @read_result = Contracts::ReadResult.new(status: "empty")
              run_turn(text, topic: "transport", entities: { query: "red vožnje", date:, time_expression: clock })
              assert_equal text, @reads.last.fetch(:entities)["query"]
              assert_equal "NAS", @reads.last.fetch(:entities)["stop"]
              assert_equal "Intergaj", @reads.last.fetch(:entities)["area_query"]
            end
          end

          def test_transport_nearest_landmark_survives_a_model_query_paraphrase
            text = "Код болнице сам. Како до најближе аутобуске станице?"
            run_turn(text, topic: "transport", operation: "start", entities: { query: "Kako do najbliže autobuske stanice?" })
            assert_equal text, @reads.last.fetch(:entities)["query"]
          end

          def test_transport_does_not_trust_a_model_supplied_fare_continuation_query
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(text: "Objavljena cijena karte")])
            run_turn("Koliko košta autobuska karta?", topic: "transport", operation: "start")
            assert_equal "fee", @state.dig(AnswerContext::KEY, "facet")
            @read_result = Contracts::ReadResult.new(status: "empty")
            text = "A za djecu?"
            run_turn(text, topic: "transport", entities: { query: "Koliko košta autobuska karta za djecu u Nepoznatovcu?" })
            assert_equal text, @reads.last.fetch(:entities)["query"]
          end

          def test_expired_fare_context_does_not_authorize_a_composed_query
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(text: "Objavljena cijena karte")])
            run_turn("Koliko košta autobuska karta?", topic: "transport", operation: "start")
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64,
                                                     now: NOW + AnswerContext::TTL + 1, capabilities: %w(public_reads))
            @read_result = Contracts::ReadResult.new(status: "empty")
            text = "A za djecu?"
            run_turn(text, topic: "transport", entities: { query: "Koliko košta autobuska karta? A za djecu?" })
            assert_equal text, @reads.last.fetch(:entities)["query"]
          end

          def test_transport_clock_refinement_preserves_reviewed_future_date_and_lineage
            run_turn("Od NAS do Intergaja 2026-09-16 poslije 06:00", topic: "transport", operation: "start",
                                                                     entities: { stop: "NAS", area_query: "Intergaj", date: "2026-09-16" })
            @state = @state.merge("entity_provenance" => @state.fetch("entity_provenance").merge("date" => "corrected"))
            run_turn("A povratak od Intergaja do NAS-a istog dana poslije 07:00?", topic: "transport",
                                                                                   entities: { stop: "Intergaj", area_query: "NAS", time_expression: "07:00" })
            assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"]
            assert_equal "07:00", @reads.last.fetch(:entities)["time_expression"]
            assert_equal "corrected", @state.fetch("entity_provenance")["date"]
            run_turn("А истог дана послије 08:00?", topic: "transport", operation: "correct", entities: { time_expression: "истог дана послије 08:00" })
            assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"]
            assert_equal "corrected", @state.fetch("entity_provenance")["date"]
          end

          def test_explicit_same_day_return_survives_model_start_and_clock_qualifiers
            %w(start switch continue).product(["07:00", "poslije 07:00h", "07:00 istog dana"]).each do |operation, expression|
              @state = StateStore.new.empty_state(@context)
              run_turn("Od NAS do Intergaja 2026-09-16 poslije 06:00", topic: "transport", operation: "start",
                                                                       entities: { stop: "NAS", area_query: "Intergaj", date: "2026-09-16" })
              run_turn("A povratak od Intergaja do NAS-a istog dana poslije 07:00?", topic: "transport", operation:,
                                                                                     entities: { stop: "Intergaj", area_query: "NAS", time_expression: expression })
              assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"], [operation, expression].inspect
              assert_equal "NAS", @reads.last.fetch(:entities)["area_query"]
            end
          end

          def test_literal_same_day_reference_does_not_depend_on_model_calendar_slots
            %w(start switch continue correct clarify).product([{}, { date: "2026-09-15" }, { time_expression: "danas" }]).each do |operation, slots|
              @state = StateStore.new.empty_state(@context)
              run_turn("Od NAS do Intergaja 2026-09-16 poslije 06:00", topic: "transport", operation: "start",
                                                                       entities: { stop: "NAS", area_query: "Intergaj", date: "2026-09-16" })
              run_turn("A povratak od Intergaja do NAS-a istog dana poslije 07:00?", topic: "transport", operation:,
                                                                                     entities: { stop: "Intergaj", area_query: "NAS" }.merge(slots))
              assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"], [operation, slots].inspect
              assert_equal "NAS", @reads.last.fetch(:entities)["area_query"]
            end
          end

          def test_return_to_active_transport_keeps_source_day_after_information_only_detour
            phrases = ["Vratimo se autobusu, od Intergaja do ATC-a. Koje linije povezujem?",
                       "Вратимо се аутобусу, од Интергаја до АТЦ-а.",
                       "Back to the bus, from Intergaj to ATC.",
                       "Vratimo se autobusu, od Intergaja do ATC-a. #{("Molim detaljno. " * 20).strip}"]
            %w(start switch continue).product(phrases, [{}, { time_expression: "06:00" }, { date: "2026-09-15", time_expression: "jutro" }]).each do |operation, text, slots|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "empty", coverage: { "transport_query_entities" => {
                                                         "stop" => "Intergaj", "area_query" => "ATC", "date" => "2026-09-16", "time_expression" => "06:00"
                                                       } })
              run_turn("Od Intergaja do ATC-a 16.9.2026. poslije 06:00", topic: "transport", operation: "start")
              @state = @state.merge("entity_provenance" => @state.fetch("entity_provenance").merge("date" => "corrected"))
              # The public report-guidance stage leaves TASK_KEYS unchanged.
              # Its separate answer context must not become the transport date.
              @read_result = Contracts::ReadResult.new(status: "empty")
              run_turn(text, topic: "transport", operation:, entities: { stop: "Intergaj", area_query: "ATC" }.merge(slots))
              read = @reads.last.fetch(:entities)
              assert_equal "2026-09-16", read["date"], [operation, text, slots].inspect
              assert_equal "06:00", read["time_expression"]
              assert_equal "corrected", @state.fetch("entity_provenance")["date"]
              assert_equal text, read["query"]
              assert_empty @handoffs
            end
          end

          def test_transport_return_does_not_overrule_new_calendar_or_fresh_question
            ["Vratimo se autobusu sutra poslije 07:00", "Vratimo se autobusu u subotu poslije 07:00",
             "Vratimo se autobusu 19.9.2026. poslije 07:00", "Back to the bus on January 5 after 07:00",
             "Kako od Intergaja do ATC-a poslije 07:00?", "Ne vraćam se autobusu, od Intergaja do ATC-a",
             "Rekao je vratimo se autobusu, od Intergaja do ATC-a",
             "Vratimo se autobusu, ali novi put od Intergaja do ATC-a",
             "Vratimo se autobusu, ne želim raniji termin",
             "Vratimo se autobusu, kako da prijavim rupu?"].each do |text|
              @state = StateStore.new.empty_state(@context)
              run_turn("Od Intergaja do ATC-a 2026-09-16 poslije 06:00", topic: "transport", operation: "start",
                                                                         entities: { stop: "Intergaj", area_query: "ATC", date: "2026-09-16" })
              run_turn(text, topic: "transport", operation: "start", entities: { time_expression: "07:00" })
              assert_nil @reads.last.fetch(:entities)["date"], text
            end
          end

          def test_transport_return_preserves_raw_clock_refinement_and_source_failures
            %w(unavailable stale).each do |status|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "empty", coverage: { "transport_query_entities" => {
                                                         "stop" => "Intergaj", "area_query" => "ATC", "date" => "2026-09-16", "time_expression" => "06:00"
                                                       } })
              run_turn("Od Intergaja do ATC-a 2026-09-16 poslije 06:00", topic: "transport", operation: "start")
              @read_result = Contracts::ReadResult.new(status:)
              text = "Vratimo se autobusu, od Intergaja do ATC-a poslije 09:00"
              result = run_turn(text, topic: "transport", operation: "start", entities: { time_expression: "jutro" })
              assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"]
              assert_equal text, @reads.last.fetch(:entities)["query"], "actual host parser receives the explicit new clock"
              assert_equal "source_unavailable", result.resolution
              assert_empty result.fact_ids
            end
          end

          def test_transport_return_does_not_claim_different_task_or_replace_protected_draft
            draft = { "reference" => "c" * 16, "revision" => 2, "expires_at" => NOW.to_f + 120 }
            suspended = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge("active_task" => "registration", "topic" => "account")
            @state = @state.merge("active_task" => "ask_information", "topic" => "transport", "draft" => draft,
                                  "suspended_task" => suspended, "entities" => { "date" => "2026-09-16" },
                                  "entity_provenance" => { "date" => "citizen" })
            result = run_turn("Vratimo se autobusu, od Intergaja do ATC-a", topic: "waste", operation: "start")
            assert_equal "clarification", result.resolution
            assert_equal draft, @state["draft"]
            assert_equal "transport", @state["topic"]
            assert_empty @reads
            assert_empty @handoffs
          end

          def test_transport_harmless_clock_qualifiers_do_not_erase_the_reviewed_day
            ["08:00 ujutro", "poslije 08:00 ujutro", "oko 08:00", "around 08:00", "08:00 sati"].each do |expression|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_required"], coverage: {
                                                         "transport_query_entities" => { "area_query" => "Janja", "date" => "2026-09-16", "time_expression" => "08:00" }
                                                       })
              run_turn("Koji autobus ide za Janju 16.9.2026. poslije 08:00?", topic: "transport", operation: "start")
              @read_result = Contracts::ReadResult.new(status: "empty")
              run_turn("Krećem sa Bijeljina (NAS).", topic: "transport", entities: { stop: "Bijeljina (NAS)", time_expression: expression })
              assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"], expression
              assert_equal "Janja", @reads.last.fetch(:entities)["area_query"]
            end
          end

          def test_transport_clock_does_not_preserve_date_across_a_calendar_change_or_new_start
            [
              ["A sutra poslije 07:00?", "07:00", "continue"],
              ["Istog dana, mislim sutra poslije 07:00", "07:00", "start"],
              ["Istog dana 2026-09-19 poslije 07:00", "07:00", "start"],
              ["A u subotu poslije 07:00?", "07:00", "continue"],
              ["A na praznik poslije 07:00?", "07:00", "continue"],
              ["A 2026-09-19 poslije 07:00?", "07:00", "continue"],
              ["A u isto vrijeme sutra?", "isto vrijeme sutra", "continue"],
              ["A za 2 dana poslije 07:00?", "07:00", "continue"],
              ["A 19. septembra poslije 07:00?", "07:00", "continue"],
              ["А 5. јануара послије 07:00?", "07:00", "continue"],
              ["A 5. svibnja poslije 07:00?", "07:00", "continue"],
              ["And May 5 after 07:00?", "07:00", "continue"],
              ["A poslije 29:00?", "29:00", "continue"],
              ["Od NAS do Intergaja poslije 07:00", "07:00", "start"]
            ].each do |text, expression, operation|
              @state = StateStore.new.empty_state(@context)
              run_turn("Od NAS do Intergaja 2026-09-16 poslije 06:00", topic: "transport", operation: "start",
                                                                       entities: { stop: "NAS", area_query: "Intergaj", date: "2026-09-16" })
              run_turn(text, topic: "transport", operation:, entities: { stop: "NAS", area_query: "Intergaj", time_expression: expression })
              assert_nil @reads.last.fetch(:entities)["date"], text
            end
          end

          def test_reader_resolved_transport_slots_survive_the_next_turn
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_required"],
                                                     coverage: { "transport_query_entities" => { "area_query" => "Intergaj", "date" => "2026-09-19" } })
            run_turn("Autobus do Intergaja u subotu", topic: "transport", operation: "start")
            assert_equal "Intergaj", @state.fetch("entities")["area_query"]
            assert_equal "2026-09-19", @state.fetch("entities")["date"]

            @read_result = Contracts::ReadResult.new(status: "empty")
            run_turn("Od NAS", topic: "transport", entities: { stop: "NAS" })
            assert_equal "Intergaj", @reads.last.fetch(:entities)["area_query"]
            assert_equal "2026-09-19", @reads.last.fetch(:entities)["date"]
          end

          def test_unavailable_calendar_preserves_only_validated_public_journey_slots
            %w(unavailable unreviewed).each do |status|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: status, warnings: ["transport_calendar_unsupported"], coverage: {
                                                         "transport_query_entities" => { "stop" => "NAS", "area_query" => "Intergaj", "date" => "2027-01-01", "actor_id" => "42" }
                                                       })
              run_turn("Od NAS do Intergaja za praznik", topic: "transport", operation: "start")
              assert_equal "NAS", @state.fetch("entities")["stop"]
              assert_equal "Intergaj", @state.fetch("entities")["area_query"]
              assert_equal "2027-01-01", @state.fetch("entities")["date"]
              refute @state.fetch("entities").has_key?("actor_id")

              @read_result = Contracts::ReadResult.new(status: "empty")
              run_turn("A 2027-01-05 tokom raspusta?", topic: "transport", entities: { date: "2027-01-05" })
              assert_equal "NAS", @reads.last.fetch(:entities)["stop"]
              assert_equal "Intergaj", @reads.last.fetch(:entities)["area_query"]
              assert_equal "2027-01-05", @reads.last.fetch(:entities)["date"]
            end
          end

          def test_transport_capability_limits_do_not_ask_for_an_origin_or_leak_to_other_topics
            %w(transport_live_status_unavailable transport_accessibility_unverified).each do |warning|
              @read_result = Contracts::ReadResult.new(status: "empty", warnings: [warning])
              transport = run_turn("Može li autobus to?", topic: "transport", operation: "start")
              assert_equal "unsupported", transport.resolution
              assert_includes transport.reply.text, I18n.t("decidim.bih.dialogue.#{warning}", locale: "sr")
              assert_nil @state["pending_slot"]
              other = run_turn("Može li parking to?", topic: "parking", operation: "start")
              refute_includes other.reply.text, I18n.t("decidim.bih.dialogue.#{warning}", locale: "sr")
            end
          end

          def test_transport_reader_metadata_cannot_set_an_identity_or_oversized_slot
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
                                                       "transport_query_entities" => { "actor_id" => "42", "area_query" => "x" * 161, "stop" => "NAS" }
                                                     })
            run_turn("Od NAS", topic: "transport", operation: "start")
            assert_equal "NAS", @state.fetch("entities")["stop"]
            refute @state.fetch("entities").has_key?("actor_id")
            refute @state.fetch("entities").has_key?("area_query")
          end

          def test_transport_reader_can_clear_stale_line_restriction_without_clearing_other_slots
            run_turn("Od NAS do Intergaja linijom G1", topic: "transport", operation: "start",
                                                       entities: { stop: "NAS", area_query: "Intergaj", route: "G1" })
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
                                                       "transport_query_invalidated_entities" => %w(route area_query actor_id),
                                                       "transport_query_entities" => { "stop" => "NAS", "area_query" => "ATC" }
                                                     })
            run_turn("A sa presjedanjem do ATC?", topic: "transport", entities: { query: "A sa presjedanjem do ATC?" })
            refute @state.fetch("entities").has_key?("route")
            assert_equal "NAS", @state.fetch("entities")["stop"]
            assert_equal "ATC", @state.fetch("entities")["area_query"]
          end

          def test_transport_reader_can_invalidate_an_ungrounded_origin_without_losing_the_travel_day
            run_turn("Od NAS do Intergaja 2026-09-16 poslije 06:00", topic: "transport", operation: "start",
                                                                     entities: { stop: "NAS", area_query: "Intergaj", date: "2026-09-16" })
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_required"], coverage: {
                                                       "transport_query_invalidated_entities" => %w(stop date actor_id active_task),
                                                       "transport_query_entities" => { "area_query" => "bolnice" }
                                                     })
            result = run_turn("Prijatelj pita odavde do bolnice", topic: "transport", entities: { stop: "bolnica" })
            assert_nil @state.fetch("entities")["stop"]
            assert_nil @state.fetch("entity_provenance")["stop"]
            assert_equal "2026-09-16", @state.fetch("entities")["date"]
            assert_equal "ask_information", @state["active_task"]
            assert_includes result.diagnostics.fetch("dropped_entity_keys"), "stop"
            @read_result = Contracts::ReadResult.new(status: "empty")
            run_turn("A poslije 07:00?", topic: "transport", entities: { time_expression: "07:00" })
            assert_nil @reads.last.fetch(:entities)["stop"]
            assert_equal "2026-09-16", @reads.last.fetch(:entities)["date"]
          end

          def test_unresolved_transport_endpoints_cannot_be_chosen_by_the_model
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_ambiguous"],
              candidates: [{ "text" => "Dvorovi (CSP)" }, { "text" => "Dvorovi (škola)" }],
              coverage: { "transport_query_entities" => { "stop" => "Dvorova", "area_query" => "Janje" } })
            run_turn("Kako iz Dvorova autobusom do Janje uz presjedanje?", topic: "transport", operation: "start",
              entities: { stop: "Dvorova", area_query: "Janje" })
            assert_equal "stop", @state["pending_slot"]

            result = run_turn("Sačuvaj oba kraja puta dok tražiš vezu.", topic: "transport",
              entities: { stop: "Dvorovi (CSP)", area_query: "Janja (centar)" })
            assert_equal "Dvorova", @reads.last.fetch(:entities)["stop"]
            assert_equal "Janje", @reads.last.fetch(:entities)["area_query"]
            assert_equal "clarification", result.resolution
            assert_equal "stop", @state["pending_slot"]

            run_turn("Polazim sa CSP, a idem do centra Janje.", topic: "transport",
              entities: { stop: "Dvorovi (CSP)", area_query: "Janja (centar)" })
            assert_equal "Dvorovi (CSP)", @reads.last.fetch(:entities)["stop"]
            assert_equal "Janja (centar)", @reads.last.fetch(:entities)["area_query"]
          end

          def test_pending_transport_endpoint_alias_is_left_for_literal_host_resolution
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_ambiguous"],
              candidates: [{ "text" => "Dvorovi (CSP)" }, { "text" => "Dvorovi (škola)" }])
            run_turn("Od Dvorova do Janje", topic: "transport", operation: "start",
              entities: { stop: "Dvorova", area_query: "Janje" })
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: {
              "transport_query_entities" => { "stop" => "Bijeljina (NAS)", "area_query" => "Janje" }
            })
            run_turn("Sa nove autobuske stanice.", topic: "transport", entities: { stop: "Bijeljina (NAS)" })
            assert_equal "Sa nove autobuske stanice.", @reads.last.fetch(:entities)["query"]
            assert_equal "Bijeljina (NAS)", @state.fetch("entities")["stop"]
            assert_equal "Janje", @state.fetch("entities")["area_query"]
          end

          def test_transport_ambiguity_names_boarding_options_and_preserves_destination
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_ambiguous"],
                                                     candidates: [{ "text" => "Dvorovi škola" }, { "text" => "Dvorovi CSP" }])
            result = run_turn("Od Dvorova do NAS", topic: "transport", operation: "start", entities: { stop: "Dvorovi", area_query: "NAS" })
            assert_equal "clarification", result.resolution
            assert_equal "stop", @state["pending_slot"]
            assert_includes result.reply.text, "Dvorovi škola"
            assert_includes result.reply.text, "Dvorovi CSP"
            assert_equal "NAS", @state.fetch("entities")["area_query"]
          end

          def test_gps_origin_with_ambiguous_destination_asks_for_destination_without_overwriting_origin
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_destination_ambiguous"],
                                                     candidates: [{ "text" => "Dvorovi škola" }, { "text" => "Dvorovi CSP" }])
            location = { latitude: 44.757056, longitude: 19.216709 }
            result = run_turn("Autobusom odavde do Dvorova", topic: "transport", operation: "start",
                                                             entities: { area_query: "Dvorovi" }, location:)

            assert_equal "clarification", result.resolution
            assert_equal "area_query", @state.fetch("pending_slot")
            refute @state.fetch("entities").has_key?("stop")
            assert_equal "Dvorovi", @state.fetch("entities").fetch("area_query")
            assert_equal location, @reads.last.fetch(:location)
            assert_includes result.reply.text, "Dvorovi škola"
            assert_includes result.reply.text, "Dvorovi CSP"
          end

          def test_transport_empty_search_discloses_its_limits_without_claiming_no_bus_exists
            @read_result = Contracts::ReadResult.new(status: "empty", warnings: ["no_feasible_journey_within_transfer_limit"],
                                                     validity: { "maximum_transfers" => 1, "minimum_transfer_minutes" => 3, "maximum_transfer_wait_minutes" => 240 })
            result = run_turn("Od NAS do ATC", topic: "transport", operation: "start", entities: { stop: "NAS", area_query: "ATC" })
            assert_equal "unsupported", result.resolution
            assert_includes result.reply.text, "najviše 1"
            assert_includes result.reply.text, "najmanje 3"
            assert_includes result.reply.text, "najviše 240"
            refute_includes result.reply.text, "nemam provjeren podatak"
          end

          def test_transport_read_uses_current_citizen_journey_text_instead_of_model_paraphrase
            raw = "Kako da stignem od centra do Dvorova sutra u podne?"
            run_turn(raw, topic: "transport", operation: "start", entities: { query: "centar", stop: "centar", time_expression: "sutra u podne" })
            assert_equal raw, @reads.last.fetch(:entities).fetch("query")
            assert_equal "centar", @reads.last.fetch(:entities).fetch("stop")
            assert_equal "sutra u podne", @reads.last.fetch(:entities).fetch("time_expression")
          end

          def test_long_transport_request_preserves_current_endpoints_beyond_old_160_char_guard
            intro = "Molim te da mi pomogneš da isplaniram putovanje autobusom. " * 4
            raw = "#{intro}Treba da putujem od NAS do Intergaja u subotu nakon 08:00."
            run_turn(raw, topic: "transport", operation: "start", entities: { query: "centar", stop: "centar" })
            assert_equal raw, @reads.last.fetch(:entities).fetch("query")
          end

          def test_supplied_activity_area_is_retained_as_a_query_and_disambiguated_without_identity
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_name_ambiguous"],
                                                     coverage: { "supplied_area_query" => "dvorovima", "area_query_source" => "citizen_activity_locative" },
                                                     candidates: [{ "kind" => "local_area", "area_kind" => "mz", "text" => "Dvorovi", "area_slug" => "mz-dvorovi" },
                                                                  { "kind" => "local_area", "area_kind" => "komsiluk", "text" => "Dvorovi", "area_slug" => "komsiluk-42" }])
            reply = run_turn("Ima li uskoro javnih okupljanja u Dvorovima?", topic: "neighborhood", operation: "start")
            assert_equal "clarification", reply.resolution
            assert_equal "dvorovima", @state.fetch("entities").fetch("area_query")
            assert_equal "citizen", @state.fetch("entity_provenance").fetch("area_query")
            assert_equal "area_query", @state.fetch("pending_slot")
            assert_includes reply.reply.text, "komšiluk Dvorovi ili mjesna zajednica Dvorovi"
            refute_includes reply.reply.text, "MZ: "
            assert_nil @state.fetch("entities")["area_slug"]
            assert_empty @handoffs

            @read_result = Contracts::ReadResult.new(status: "empty")
            next_reply = run_turn("MZ Dvorovi", topic: "neighborhood", entities: { area_query: "MZ Dvorovi" })
            assert_equal "unsupported", next_reply.resolution
            assert_equal "MZ Dvorovi", @reads.last.fetch(:entities).fetch("area_query")
            assert_nil @state.fetch("entities")["area_slug"]
          end

          def test_supplied_activity_area_cannot_replace_explicit_scope_and_time_ambiguity_keeps_it
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["unsupported_time_expression"],
                                                     coverage: { "supplied_area_query" => "dvorovima", "area_query_source" => "citizen_activity_locative" })
            run_turn("Ima li okupljanja u Dvorovima?", topic: "neighborhood", operation: "start")
            assert_equal "time_expression", @state.fetch("pending_slot")
            assert_equal "dvorovima", @state.fetch("entities").fetch("area_query")

            @state = StateStore.new.empty_state(@context)
            run_turn("Ima li okupljanja u Dvorovima?", topic: "neighborhood", operation: "start", entities: { area_query: "Janja" })
            assert_equal "Janja", @state.fetch("entities").fetch("area_query")
            assert_nil @state.fetch("entities")["area_slug"]
          end

          def test_supplied_area_choice_accepts_public_catalog_shape_and_fails_closed_on_non_area_candidates
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_name_ambiguous"],
                                                     candidates: [{ "slug" => "mz-dvorovi", "kind" => "mz", "label" => "Dvorovi" },
                                                                  { "slug" => "komsiluk-42", "kind" => "komsiluk", "label" => "Dvorovi" }])
            reply = run_turn("Volonterske akcije u Dvorovima", topic: "volunteer", operation: "start", entities: { area_query: "Dvorovi" })
            assert_includes reply.reply.text, "komšiluk Dvorovi ili mjesna zajednica Dvorovi"
            refute_includes reply.reply.text, "MZ: "
            assert_nil @state.fetch("entities")["area_slug"]
            @read_result = Contracts::ReadResult.new(status: "ambiguous", candidates: [{ "kind" => "account", "label" => "private" }])
            reply = run_turn("Dvorovi", topic: "volunteer", entities: { area_query: "Dvorovi" })
            refute_includes reply.reply.text, "private"
          end

          def test_parking_location_clarification_uses_current_color_followup
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["parking_zone_required"])
            first = run_turn("Kako da platim parking ovdje?", topic: "parking", operation: "start", entities: { query: "Kako da platim parking ovdje?" })

            assert_equal "clarification", first.resolution
            assert_equal "area_query", @state["pending_slot"]
            assert_includes first.reply.text, "bijela, crvena ili plava"
            @read_result = Contracts::ReadResult.new(status: "empty")
            second = run_turn("U plavoj zoni.", topic: "parking", entities: { area_query: "plava zona", query: "Kako da platim parking ovdje?" })

            assert_equal "U plavoj zoni.", @reads.last.fetch(:entities).fetch("query")
            assert_equal "unsupported", second.resolution
            assert_nil @state["pending_slot"]
          end

          def test_parking_zone_clarification_copy_is_available_in_every_dialogue_locale
            Contracts::LOCALES.each do |locale|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["parking_zone_required"])
              result = run_turn("Parking ovdje?", topic: "parking", operation: "start", locale:)

              assert_equal "clarification", result.resolution
              assert_equal I18n.t("decidim.bih.dialogue.ask_parking_zone", locale:), result.reply.text
            end
          end

          def test_registration_information_answers_terms_without_claiming_acceptance
            result = run_turn("Gdje prihvatam obavezne uslove?", topic: "account", operation: "start", entities: { query: "Gdje prihvatam obavezne uslove?" })

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "obavezno"
            assert_includes result.reply.text, "dobrovoljno"
            assert_includes result.reply.text, "/users/sign_up"
            assert_equal ["registration"], (@handoffs.map { |call| call[:action] })
            assert_empty @reads
            refute result.handoff_completed
          end

          def test_registration_information_preserves_account_task_and_suspended_parking
            run_turn("Parking", topic: "parking", operation: "start")
            run_turn("Registracija", action: "registration", topic: "account", operation: "switch")
            suspended = @state.fetch("suspended_task")
            result = run_turn("A uslovi?", topic: "account", entities: { query: "uslovi registracije" })

            assert_equal "answered", result.resolution
            assert_equal "registration", @state["active_task"]
            assert_equal suspended, @state["suspended_task"]
            assert_includes result.reply.text, "obavezno"
            refute result.handoff_completed
          end

          def test_registration_information_does_not_reuse_an_old_subquestion
            run_turn("Uslovi?", topic: "account", operation: "start", entities: { query: "uslovi" })
            result = run_turn("A šta još?", topic: "account")

            assert_equal "clarification", result.resolution
            assert_equal "query", @state["pending_slot"]
            assert_equal 1, @handoffs.length
            refute_includes result.reply.text, "Prihvatanje uslova je obavezno"
          end

          def test_registration_information_never_converts_an_existing_account_into_consent
            @handoff_result = Contracts::HandoffResult.new(account_state: "verified", next_step: "registered", destination: "/mi/account", completed: true)
            result = run_turn("Da li je bilten obavezan?", topic: "account", operation: "start")

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "Izbor je dobrovoljan"
            assert_includes result.reply.text, "sve četiri teme"
            refute_includes result.reply.text, "već završen"
            refute result.handoff_completed
          end

          # R5 (b3c35): the account menu twice, for two questions whose answers
          # already existed. "Ne želim novosti" was answered correctly the
          # whole time, which is what proves these were vocabulary gaps rather
          # than missing answers: NEWSLETTER matched only novost|bilten|
          # newsletter and TERMS only uslov|uvjet.
          def test_the_newsletter_and_terms_vocabularies_cover_the_words_citizens_used
            {
              "Moram li prihvatiti promotivne poruke da koristim MI?" => ["Izbor je dobrovoljan", "sve četiri teme"],
              "Da li su reklamne poruke obavezne?" => ["Izbor je dobrovoljan", "sve četiri teme"],
              "Koja saglasnost je obavezna pri registraciji?" => %w(obavezno dobrovoljno),
              "Gdje dajem pristanak pri registraciji?" => %w(obavezno)
            }.each do |question, fragments|
              @state = StateStore.new.empty_state(@context)
              @handoffs.clear
              result = run_turn(question, topic: "account", operation: "start")

              assert_equal "answered", result.resolution, question
              refute_equal I18n.t("decidim.bih.dialogue.account_help_clarify", locale: "sr"), result.reply.text, question
              fragments.each { |fragment| assert_includes result.reply.text, fragment, question }
              refute result.handoff_completed, question
            end
          end

          # The facets stay two different answers: a marketing question is the
          # newsletter, a consent question is the terms.
          def test_the_widened_vocabularies_keep_the_two_facets_apart
            assert_equal "newsletter", AccountQuestion.facet("Moram li prihvatiti promotivne poruke da koristim MI?")
            assert_equal "terms", AccountQuestion.facet("Koja saglasnost je obavezna pri registraciji?")
            # Controls: neither word may claim a turn that is about something else.
            assert_nil AccountQuestion.facet("Ima li promotivnih cijena za parking?")
          end

          def test_registration_information_retains_destination_and_credential_guards
            @handoff_result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "javascript:alert(1)")
            assert_raises(Contracts::Invalid) { run_turn("Uslovi?", topic: "account", operation: "start") }
            @state = StateStore.new.empty_state(@context)
            @handoffs.clear
            result = run_turn("Moj kod je 123456, uslovi?", topic: "account", operation: "start")

            assert_equal "unsupported", result.resolution
            assert_empty @handoffs
          end

          def test_registration_information_matches_cyrillic_and_english_current_questions
            { "sr-Cyrl" => ["Гдје прихватам услове?", "обавезно"], "en" => ["Where do I accept the terms?", "required"] }.each do |locale, (question, expected)|
              @state = StateStore.new.empty_state(@context)
              result = run_turn(question, topic: "account", operation: "start", locale:)

              assert_equal "answered", result.resolution
              assert_includes result.reply.text, expected
              refute result.handoff_completed
            end
          end

          def test_phone_information_explains_the_registration_purpose_in_each_locale
            {
              "sr" => ["Zašto vam treba moj telefon?", "potvrdu pristupa", "nisam poslala"],
              "sr-Cyrl" => ["Зашто вам треба мој телефон?", "потврду приступа", "нисам послала"],
              "bs" => ["Zašto trebate broj telefona?", "potvrdu pristupa", "nisam poslala"],
              "hr" => ["Zašto trebate moj mobitel?", "potvrdu pristupa", "nisam poslala"],
              "en" => ["Why do you need my phone?", "verify access", "have not sent"]
            }.each do |locale, (question, purpose, no_send)|
              @state = StateStore.new.empty_state(@context)
              @handoffs.clear
              result = run_turn(question, topic: "account", operation: "start", locale:)

              assert_equal "answered", result.resolution
              assert_includes result.reply.text, purpose
              assert_includes result.reply.text, no_send
              assert_equal 1, result.reply.text.scan("/users/sign_up").length
              assert_equal ["registration"], (@handoffs.map { |call| call[:action] })
              assert_empty @reads
              refute result.handoff_completed
            end
          end

          def test_phone_information_does_not_guess_account_change_instructions
            ["Kako da promijenim broj telefona?", "Šta mi treba da promijenim broj telefona?",
             "Šta mi treba za promjenu broja telefona?", "Da li je obavezna izmjena telefona?",
             "Šta mi treba za zamjenu telefona?",
             "Зашто не могу промијенити телефон?", "Why do I need to change my phone number?",
             "I need to remove my phone number"].each do |question|
              @state = StateStore.new.empty_state(@context)
              result = run_turn(question, topic: "account", operation: "start")

              assert_equal "clarification", result.resolution
              assert_empty @handoffs
              refute result.handoff_completed
            end
          end

          def test_phone_information_keeps_credential_and_destination_guards
            secret = run_turn("Moj kod je 123456, zašto telefon?", topic: "account", operation: "start")
            assert_equal "unsupported", secret.resolution
            assert_empty @handoffs
            @state = StateStore.new.empty_state(@context)
            @handoff_result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "javascript:alert(1)")

            assert_raises(Contracts::Invalid) { run_turn("Zašto telefon?", topic: "account", operation: "start") }
          end

          def test_account_information_resolves_pending_query_only_after_a_supported_answer
            run_turn("Šta mi treba za zamjenu telefona?", topic: "account", operation: "start", entities: { query: "zamjena telefona" })
            assert_equal "query", @state["pending_slot"]
            result = run_turn("Uslovi?", topic: "account")

            assert_equal "answered", result.resolution
            assert_nil @state["pending_slot"]
            assert_equal 0, @state["clarification_count"]
          end

          # Task 5 — the menu is asked ONCE. The identical clarification used to
          # come back twice in a row in six rated conversations (b3c01–b3c04,
          # b3c11–b3c14), once immediately after the citizen answered "Ništa od
          # toga". A second unresolved account turn now gets a working route.
          #
          # "Kako brišem nalog?" is no longer an example of an unsupported
          # account query — deletion guidance is one of the journeys this task
          # added — so the probe is a question we genuinely have no answer for.
          def test_a_second_unresolved_account_turn_gets_a_route_instead_of_the_menu
            probe = "Šta mi treba za zamjenu telefona?"
            first = run_turn(probe, topic: "account", operation: "start", entities: { query: probe })

            assert_equal "clarification", first.resolution
            assert_equal 1, @state["clarification_count"]
            assert_empty @handoffs

            second = run_turn(probe, topic: "account", entities: { query: probe })

            assert_equal "handoff", second.resolution
            assert_equal ["registration"], (@handoffs.map { |call| call[:action] })
            assert_includes second.reply.text, "/users/sign_up"
            refute_includes second.reply.text, I18n.t("decidim.bih.dialogue.account_help_clarify", locale: "sr")
          end

          # b4c02, handed over by Task 6 — ReadPort already returns a distinct
          # +no_owned_reports+ warning for "you have no reports" and the runner
          # still rendered it as "Za ovo nemam provjeren podatak", the refusal
          # it uses when it could not find out at all. The two are not the same
          # answer and no longer share a label.
          def test_an_own_report_read_that_found_nothing_is_an_answer_not_a_refusal
            coverage = { "ownership" => "actor", "scope" => "most_recent_owned_reports" }
            @read_result = Contracts::ReadResult.new(status: "empty", warnings: ["no_owned_reports"], coverage:)
            result = own_report_status_turn

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "još nema nijedne prijave"
            assert_includes result.reply.text, "/mi/prijavi"
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.no_match", locale: "sr")
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.coverage_limit", locale: "sr")
          end

          def test_an_empty_read_without_that_warning_is_still_the_honest_refusal
            @read_result = Contracts::ReadResult.new(status: "empty")
            result = own_report_status_turn

            assert_equal "unsupported", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.no_match", locale: "sr")
          end

          def own_report_status_turn
            run_turn("Koje su moje prijave?", action: "report_status", topic: "report", operation: "start",
                                              entities: { query: "koje su moje prijave" })
          end

          # == Task 5: the nine account journeys
          #
          # Each case names the rated conversation it closes. The rule they
          # share: the citizen's OWN words decide which journey this is, so a
          # menu option plus a clarifying sentence resolves exactly like the
          # bare option did.

          # b3c09 — "Koliko traje link za potvrdu?" got the menu twice. The two
          # lifetimes are purpose-specific and must never collapse into one.
          def test_the_verification_lifetime_answer_keeps_verify_and_login_apart
            result = run_turn("Koliko traje link za potvrdu?", topic: "account", operation: "start", entities: { query: "koliko traje link" })

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "24 sata"
            assert_includes result.reply.text, "10 minuta"
            assert_equal ["registration"], (@handoffs.map { |call| call[:action] })

            follow_up = run_turn("Mislim na potvrdu telefona nakon registracije. Koliko sati važi?", topic: "account")

            assert_equal "answered", follow_up.resolution
            assert_includes follow_up.reply.text, "24 sata"
          end

          # b3c03, b3c04, b3c08 — the typed code and the missing message are the
          # two ways in that dead-ended on the menu.
          def test_the_code_and_the_missing_message_are_two_different_answers
            code = run_turn("Imam računar i obični telefon. Mogu li ručno prepisati kod iz SMS-a?", topic: "account", operation: "start")

            assert_equal "answered", code.resolution
            assert_includes code.reply.text, "Imam kod iz SMS-a"

            @state = StateStore.new.empty_state(@context)
            missing = run_turn("Nisam dobio SMS, šta sad?", topic: "account", operation: "start")

            assert_equal "answered", missing.resolution
            assert_includes missing.reply.text, "novo slanje"
            refute_equal code.reply.text, missing.reply.text
          end

          def test_the_code_answer_reaches_a_citizen_without_a_smartphone_in_cyrillic
            result = run_turn("Могу ли без паметног телефона, имам само СМС?", topic: "account", operation: "start", locale: "sr-Cyrl")

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.account_code_entry", locale: "sr-Cyrl", url: "/users/sign_up")
          end

          # b3c01 — "Šta mi treba za to i dobijam li nešto?" was answered with
          # the register link three times. Registration is worth 20 points and
          # the corpus never says so once.
          def test_registration_states_its_effective_award_from_the_schedule
            result = run_turn("Šta mi treba za to i dobijam li nešto?", action: "registration", topic: "account", operation: "continue")

            assert_equal "answered", result.resolution
            verification = Decidim::Bih::Goodwill::EarningRules.points_for_action(:verification)
            area = Decidim::Bih::Goodwill::EarningRules.points_for_action(:komsiluk_selected)

            assert_includes result.reply.text, (verification + area).to_s
            assert_includes result.reply.text, "potvrđen broj telefona"
            refute result.handoff_completed
          end

          def test_the_required_fields_answer_lists_the_form_not_the_points
            result = run_turn("Molim samo spisak obaveznih podataka, u jednoj rečenici.", action: "registration", topic: "account", operation: "continue")

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "broj telefona"
            assert_includes result.reply.text, "komšiluka"
          end

          # b3c11, b3c12, b3c13, b3c14, b3c16 — five journeys, five answers, all
          # of them the same menu before this task.
          def test_each_account_journey_has_its_own_answer
            journeys = {
              "Da li drugi građani vide broj telefona s mog naloga?" => "nije javan",
              "Zašto tražite broj pri registraciji? Ukratko." => "potvrdu pristupa",
              "Kako mogu zatražiti brisanje naloga? Nemoj ništa brisati." => "ništa ne brišem",
              "Gdje su postavke mog naloga?" => "Postavke su na stranici tvog naloga",
              "Mogu li otvoriti MI nalog bez email adrese?" => "ne potvrđuje nalog",
              "Živim van Bijeljine, smijem li otvoriti nalog?" => "izbor komšiluka sam po sebi nije provjera prebivališta",
              "Da li se registracija i potvrda adrese razlikuju?" => "30 dana",
              "Kako da se odjavim sa MI platforme na zajedničkom računaru?" => "Odjavi se"
            }
            answers = journeys.map do |question, expected|
              @state = StateStore.new.empty_state(@context)
              result = run_turn(question, topic: "account", operation: "start")

              assert_equal "answered", result.resolution, question
              assert_includes result.reply.text, expected, question
              result.reply.text
            end

            assert_equal answers.uniq.length, answers.length, "every journey has its own answer"
          end

          # b3c16 t2 — "Ne registracija, nego odjava postojećeg naloga" was read
          # as a cancellation and answered "U redu, odustali smo od ovog
          # zadatka". A contrastive correction is not a cancel.
          def test_a_contrastive_account_correction_is_answered_not_cancelled
            run_turn("Kako da se odjavim?", topic: "account", operation: "start")
            result = run_turn("Ne registracija, nego odjava postojećeg naloga.", action: "cancel", topic: "account", operation: "cancel")

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "Odjavi se"
            refute_equal I18n.t("decidim.bih.dialogue.cancelled", locale: "sr"), result.reply.text
          end

          def test_an_ordinary_cancellation_still_cancels
            run_turn("Kako da se odjavim?", topic: "account", operation: "start")
            result = run_turn("Odustani", action: "cancel", topic: "account", operation: "cancel")

            assert_equal "cancelled", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.cancelled", locale: "sr"), result.reply.text
          end

          # b4c03 — a SIGNED-IN citizen asked whether they must register again
          # and got the menu. Whatever else happens, the answer is never
          # "register".
          def test_a_signed_in_citizen_is_never_told_to_register_again
            @handoff_result = Contracts::HandoffResult.new(account_state: "verified", next_step: "signed_in",
                                                           destination: "/mi/moj-nalog", completed: true)
            result = run_turn("Već sam prijavljen, da li moram ponovo?", action: "registration", topic: "account", operation: "start")

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "Ne moraš ponovo"
            assert_equal ["sign_in"], (@handoffs.map { |call| call[:action] })
            refute_includes result.reply.text, "/users/sign_up"
          end

          def test_an_unverified_account_asking_the_same_thing_gets_its_real_next_step
            @handoff_result = Contracts::HandoffResult.new(account_state: "unverified", next_step: "verify", destination: "/mi/verifikacija")
            result = run_turn("Već sam prijavljen, da li moram ponovo?", action: "registration", topic: "account", operation: "start")

            assert_equal "handoff", result.resolution
            assert_includes result.reply.text, "/mi/verifikacija"
            refute_includes result.reply.text, "Ne moraš ponovo"
          end

          # b3c15 — two rated positive controls. A password question is a
          # sign-in route, never an explanation of why we ask for a phone.
          def test_password_and_phone_sign_in_questions_stay_on_the_sign_in_route
            ["Zaboravio sam lozinku, kako da uđem na svoj nalog?",
             "Mogu li se prijaviti telefonom umjesto lozinkom? Bez slanja poruke sada."].each do |question|
              @state = StateStore.new.empty_state(@context)
              @handoffs.clear
              @handoff_result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "sign_in", destination: "/users/sign_in")
              result = run_turn(question, action: "sign_in", topic: "account", operation: "start")

              assert_equal "handoff", result.resolution, question
              assert_equal ["sign_in"], (@handoffs.map { |call| call[:action] }), question
              assert_includes result.reply.text, "/users/sign_in"
            end
          end

          def test_the_account_menu_offers_chips_whose_own_words_resolve_on_their_own
            result = run_turn("Pomozi mi oko naloga", topic: "account", operation: "start", entities: { query: "pomozi mi oko naloga" })

            assert_equal "clarification", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.account_help_clarify", locale: "sr"), result.reply.text
            chips = result.reply.quick_replies

            assert_equal 4, chips.length
            chips.each { |chip| assert_equal chip.fetch(:label), chip.fetch(:send), "a chip must send what it says" }
            facets = chips.map { |chip| AccountQuestion.facet(chip.fetch(:send)) }

            assert_equal %w(register sign_in verify terms), facets
          end

          # R8 — the opening menu names four things and, across 23 occurrences
          # in the 14.09 corpus, offered no way to tap one. The account menu one
          # level down already had chips; this is the same rule one level up.
          def test_the_opening_menu_offers_a_chip_for_each_thing_it_names
            result = run_turn("???", action: "help", topic: "unknown", operation: "clarify", clarification: true)

            assert_equal "clarification", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.clarify", locale: "sr"), result.reply.text
            chips = result.reply.quick_replies

            assert_equal 4, chips.length
            chips.each { |chip| assert_equal chip.fetch(:label), chip.fetch(:send), "a chip must send what it says" }
            assert_equal ["Želim prijaviti problem", "Pomoć s nalogom", "Kada se odvozi smeće?",
                          "Šta ima novo u mom komšiluku?"], (chips.map { |chip| chip.fetch(:send) })
          end

          # A pending slot asks its OWN question ("Za koji dan pitaš?"), and the
          # four-way menu chips would contradict it — tapping one would abandon
          # the slot the previous turn just asked for.
          def test_a_pending_slot_question_carries_no_four_way_menu
            run_turn("Kada se odvozi smeće?", topic: "waste", operation: "start", entities: { query: "kada se odvozi smece" })
            @state = @state.merge("pending_slot" => "area_query")
            result = run_turn("???", action: "help", topic: "unknown", operation: "clarify", clarification: true)

            assert_equal "clarification", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.ask_area_query_again", locale: "sr"), result.reply.text
            assert_empty result.reply.quick_replies
          end

          def test_account_information_resume_asks_relevant_help_without_reusing_query
            run_turn("Uslovi?", topic: "account", operation: "start", entities: { query: "uslovi" })
            run_turn("A parking?", topic: "parking", operation: "switch")
            @reads.clear
            result = run_turn("nastavi", action: "help", topic: "unknown", clarification: true)

            assert_equal "clarification", result.resolution
            assert_equal "account", @state["topic"]
            assert_includes result.reply.text, "otvaranje naloga"
            assert_empty @reads
            assert_equal 1, @handoffs.length
          end

          def test_account_information_preserves_pending_account_area_selection
            @state = @state.merge("active_task" => "choose_area", "topic" => "account", "pending_slot" => "area_query", "clarification_count" => 1)
            result = run_turn("Uslovi?", topic: "account")

            assert_equal "answered", result.resolution
            assert_equal "choose_area", @state["active_task"]
            assert_equal "area_query", @state["pending_slot"]
            assert_equal 1, @state["clarification_count"]
          end

          def test_standalone_registration_does_not_repeat_unrelated_draft_return_warning
            result = run_turn("Kako da se registrujem?", action: "registration", topic: "account", operation: "start")

            assert_equal "handoff", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.handoff_register", locale: "sr", url: "/users/sign_up")
            refute_includes result.reply.text, "Automatski povratak"
            refute result.handoff_completed
          end

          def test_switch_from_empty_or_control_state_never_suspends_an_invalid_task
            [nil, *ProcedureRunner::CONTROL_ACTIONS].each do |previous|
              @state = StateStore.new.empty_state(@context).merge("active_task" => previous)
              result = run_turn("A parking?", topic: "parking", operation: "switch")

              assert_equal "unsupported", result.resolution
              assert_nil @state["suspended_task"]
              assert_equal "parking", @state["topic"]
              assert StateStore.new.validate(context: @context, state: @state)
            end
          end

          def test_parking_registration_and_explicit_return_resume_one_task_without_claiming_registration
            run_turn("Koliko košta parking?", topic: "parking", operation: "start")
            registration = run_turn("Kako da se registrujem?", action: "registration", topic: "account", operation: "switch")
            assert_equal "parking", @state.dig("suspended_task", "topic")
            assert_equal "handoff", registration.resolution
            assert registration.handoff_offered
            refute registration.handoff_completed
            assert_includes registration.reply.text, I18n.t("decidim.bih.dialogue.handoff_register", locale: "sr", url: "/users/sign_up")
            assert_includes registration.reply.text, "Automatski povratak"
            run_turn("gotovo", action: "registration", topic: "account")
            assert_equal 2, @handoffs.size # Citizen assertion does not replace backend observation.
            assert_equal "anonymous", @handoff_result.account_state
            resumed = run_turn("nastavi", action: "help", clarification: true)
            assert_equal "parking", @state["topic"]
            assert_nil @state["suspended_task"]
            assert_equal "unsupported", resumed.resolution
            assert_equal "parking", @reads.last[:topic]
          end

          def test_resume_offer_is_made_once_per_suspension_and_again_after_a_new_suspension
            offer = I18n.t("decidim.bih.dialogue.resume_offer", locale: :sr)
            run_turn("Želim prijaviti rupu", action: "report_problem", topic: "roads", operation: "start", entities: { description: "Rupa na putu" })
            assert_equal false, @state.fetch("resume_offered")

            first = run_turn("Kako da se registrujem?", action: "registration", topic: "account", operation: "switch")
            assert_equal "roads", @state.dig("suspended_task", "topic")
            assert_includes first.reply.text, offer
            assert_equal true, @state.fetch("resume_offered")

            second = run_turn("gotovo", action: "registration", topic: "account")
            assert_equal "handoff", second.resolution
            refute_includes second.reply.text, offer, "the offer is made once per suspension"
            assert_equal true, @state.fetch("resume_offered")

            resumed = run_turn("nastavi", action: "help", clarification: true)
            assert_equal "clarification", resumed.resolution
            assert_nil @state["suspended_task"]
            assert_equal false, @state.fetch("resume_offered")
            refute_includes resumed.reply.text, offer

            again = run_turn("Kako da se registrujem?", action: "registration", topic: "account", operation: "switch")
            assert_equal "roads", @state.dig("suspended_task", "topic")
            assert_includes again.reply.text, offer, "a new suspension is offered again"
            refute_includes run_turn("gotovo", action: "registration", topic: "account").reply.text, offer
          end

          def test_green_zone_facts_render_human_checked_time_without_the_field_disclaimer
            @read_result = Contracts::ReadResult.new(
              status: "ok", checked_at: Time.iso8601("2026-06-29T00:00:00+02:00"), warnings: ["tariff_snapshot_not_live"],
              coverage: { "area_slugs" => ["centar"], "reviewed_on" => "2026-06-29" },
              facts: [fact("id" => "parking:centar", "kind" => "parking_tariff", "text" => "Centar: crvena zona, 1 KM po satu.",
                           "source_id" => "parking_operator", "source_url" => "https://parking.example/tarife")]
            )
            result = run_turn("Koliko košta parking u Centru?", topic: "parking", operation: "start", entities: { area_query: "Centar" })

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.checked_at", locale: :sr, time: "29.6.2026.")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.coverage", locale: :sr, coverage_text: "Centar")
            refute_includes result.reply.text, "2026-06-29", "the reviewed date already shown as checked_at is not repeated"
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.coverage_limit", locale: :sr), "a tariff is not a field condition"
          end

          def test_field_topics_keep_the_disclaimer_and_every_time_is_human
            @read_result = Contracts::ReadResult.new(
              status: "ok", checked_at: Time.utc(2026, 9, 4, 8), warnings: ["gauge_snapshot"],
              facts: [fact("id" => "level:sava", "kind" => "water_level_reading", "text" => "Sava kod Rače: 312 cm.",
                           "checked_at" => "2026-09-04T08:00:00Z", "observed_at" => "2026-09-04T06:30:00Z", "source_published_at" => "2026-09-01")]
            )
            result = run_turn("Kakav je vodostaj Save?", topic: "water_levels", operation: "start")

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.coverage_limit", locale: :sr)
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.checked_at", locale: :sr, time: "juče u 10:00")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.fact_observed_at", locale: :sr, time: "juče u 08:30")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.fact_source_published_at", locale: :sr, time: "1.9.2026.")
            refute_match(/\d{4}-\d{2}-\d{2}/, result.reply.text, "no ISO timestamp reaches the citizen")
          end

          def test_answer_intent_follows_the_topic_for_green_zone_reads
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact("id" => "waste:dvorovi", "kind" => "waste_schedule", "text" => "Dvorovi: ponedjeljak i četvrtak.")])
            assert_equal "waste", run_turn("Kad se odvozi smeće u Dvorovima?", topic: "waste", operation: "start", entities: { area_query: "Dvorovi" }).reply.answer_intent

            @state = StateStore.new.empty_state(@context)
            @read_result = Contracts::ReadResult.new(
              status: "ok", facts: [fact("id" => "budget:2026:csr", "kind" => "budget_line", "text" => "Centar za socijalni rad: 1.200.000 KM.")]
            )
            assert_equal "budget", run_turn("Koliko je u budžetu za socijalni rad?", topic: "budget", operation: "start", entities: { query: "socijalni rad" }).reply.answer_intent

            @state = StateStore.new.empty_state(@context)
            @read_result = Contracts::ReadResult.new(status: "empty")
            assert_equal "gazette", run_turn("Šta piše u Službenom glasniku?", topic: "gazette", operation: "start", entities: { query: "glasnik" }).reply.answer_intent

            @state = StateStore.new.empty_state(@context)
            assert_equal "service", run_turn("Ima li struje u Dvorovima?", topic: "electricity", operation: "start", entities: { area_query: "Dvorovi" }).reply.answer_intent
          end

          def test_water_area_and_tomorrow_followups_preserve_topic_and_clock_owned_relative_time
            run_turn("Ima li najavljenog prekida vode?", topic: "water", operation: "start")
            assert_equal "area_query", @state["pending_slot"]
            run_turn("U Dvorovima", entities: { area_query: "Dvorovi" })
            assert_equal "water", @reads.last[:topic]
            run_turn("A sutra?", entities: { time_expression: "sutra", date: "2099-01-01" })
            assert_equal "water", @reads.last[:topic]
            assert_equal "Dvorovi", @reads.last[:entities]["area_query"]
            assert_equal "sutra", @reads.last[:entities]["time_expression"]
            refute @reads.last[:entities].has_key?("date")
            assert_equal NOW, @reads.last[:context].now
          end

          def test_transport_price_query_does_not_hijack_the_next_journey_or_lose_a_destination
            query = "Koliko košta autobuska karta?"
            run_turn(query, topic: "transport", operation: "start", entities: { query: })
            assert_equal query, @reads.last[:entities]["query"]

            run_turn("Do Naselja Primjer", topic: "transport", entities: { area_query: "Naselje Primjer" })
            assert_equal "Do Naselja Primjer", @reads.last[:entities]["query"]
            assert_equal "Naselje Primjer", @reads.last[:entities]["area_query"]

            @state = StateStore.new.empty_state(@context)
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_origin_required"], coverage: {
                                                       "transport_query_entities" => { "area_query" => "Naselje Primjer" }
                                                     })
            run_turn("Do Naselja Primjer", topic: "transport", operation: "start", entities: { query: "Naselje Primjer" })
            @read_result = Contracts::ReadResult.new(status: "empty")
            run_turn("Od Stanice Primjer", topic: "transport", entities: { stop: "Stanica Primjer" })
            assert_equal "Od Stanice Primjer", @reads.last[:entities]["query"]
            assert_equal "Naselje Primjer", @reads.last[:entities]["area_query"]
            assert_equal "Stanica Primjer", @reads.last[:entities]["stop"]
          end

          def test_utility_publication_source_questions_read_without_requiring_location
            [
              ["water", "Gdje Vodovod objavljuje servisne informacije?"],
              ["electricity", "Gdje se objavljuju planirana isključenja struje?"],
              ["water", "Гдје се објављују прекиди воде?"],
              ["electricity", "Where are planned power cuts published?"],
              ["electricity", "Koja je službena stranica Elektro Bijeljine?"],
              ["heating", "Гдје Топлана објављује обавјештења?"],
              ["water", "What is the official website of the water utility?"]
            ].each do |topic, query|
              @state = StateStore.new.empty_state(@context)
              @reads.clear
              result = run_turn(query, topic:, operation: "start", entities: { query: })

              assert_equal "unsupported", result.resolution, query
              assert_equal 1, @reads.length, query
              assert_equal topic, @reads.last[:topic]
              assert_equal query, @reads.last[:entities]["query"]
              assert_nil @state["pending_slot"]
              assert_empty @handoffs
            end
          end

          # Task 4: a contact/website/opening-hours question is answered from
          # the reviewed directory card, which needs no neighbourhood. Asking
          # "u kojoj mjesnoj zajednici?" for a phone number was the defect
          # (b1c12 t1), not the contract.
          def test_a_contact_question_reads_the_directory_without_asking_for_an_area
            [
              ["water", "Koji je telefon Vodovoda?"],
              ["heating", "Ko upravlja gradskim grijanjem i gdje mogu vidjeti kontakt?"],
              ["electricity", "Kako da ih kontaktiram?"]
            ].each do |topic, query|
              @state = StateStore.new.empty_state(@context)
              @reads.clear
              result = run_turn(query, topic:, operation: "start", entities: { query: })

              assert_equal 1, @reads.length, query
              assert_equal query, @reads.last[:entities]["query"], query
              assert_nil @state["pending_slot"], query
              assert_equal "unsupported", result.resolution, query
            end
          end

          # The same question with no area, asked over an ENTITY-FREE follow-up
          # turn: the citizen's own words, not the retained question, decide.
          def test_an_entity_free_follow_up_sends_the_citizens_own_words_to_the_reader
            run_turn("Kada se odvozi smeće?", topic: "waste", operation: "start", entities: { query: "odvoz smeća" })
            run_turn("Da li Komunalac radi subotom?", topic: "waste", entities: {})

            assert_equal "Da li Komunalac radi subotom?", @reads.last[:entities]["query"]
          end

          def test_utility_outages_dates_and_unsupported_contacts_keep_pre_read_location_guard
            [
              {},
              { query: "Ne želim službenu stranicu Vodovoda" },
              { query: "Not the official website" },
              { query: "Gdje Vodovod objavljuje servisne informacije i ima li prekida vode?" },
              { query: "Gdje Vodovod objavljuje informacije i ima li vode?" },
              { query: "Gdje su objave i planirani prekidi vode?" },
              { query: "Gdje se objavljuju prekidi vode danas?" },
              { query: "What is the official water website and is the water working?" },
              { query: "What is the official website and the current water status?" },
              { query: "Gdje Vodovod objavljuje servisne informacije danas?" },
              { query: "Gdje Vodovod objavljuje servisne informacije?", time_expression: "sutra" }
            ].each do |entities|
              @state = StateStore.new.empty_state(@context)
              result = run_turn(entities.fetch(:query, "Voda?"), topic: "water", operation: "start", entities:)

              assert_equal "clarification", result.resolution, entities.inspect
              assert_equal "area_query", @state["pending_slot"]
              assert_empty @reads
            end
          end

          def test_utility_outage_followup_never_reuses_a_saved_publication_query
            query = "Gdje Vodovod objavljuje servisne informacije?"
            run_turn(query, topic: "water", operation: "start", entities: { query: })
            result = run_turn("Nema vode", topic: "water")

            assert_equal "clarification", result.resolution
            assert_equal "area_query", @state["pending_slot"]
            assert_equal 1, @reads.length
            assert_equal query, @state["entities"]["query"]

            run_turn("U Dvorovima", entities: { area_query: "Dvorovi" })
            assert_equal 2, @reads.length
            assert_equal "water", @reads.last[:topic]
            assert_equal "Dvorovi", @reads.last[:entities]["area_query"]
            assert_empty @reads.last[:entities]["query"]
          end

          def test_utility_publication_question_resumes_after_registration_without_requiring_location
            query = "Gdje Vodovod objavljuje servisne informacije?"
            run_turn(query, topic: "water", operation: "start", entities: { query: })
            run_turn("Registracija", action: "registration", topic: "account", operation: "switch")
            result = run_turn("nastavi", action: "help", clarification: true)

            assert_equal "unsupported", result.resolution
            assert_equal "water", @state["topic"]
            assert_nil @state["suspended_task"]
            assert_nil @state["pending_slot"]
            assert_equal 2, @reads.length
            assert_equal query, @reads.last[:entities]["query"]
          end

          def test_resuming_a_saved_own_read_copies_frozen_entity_maps_before_normalizing_the_query
            @context = @context.with(actor_id: 11, account_state: "registered", capabilities: %w(public_reads own_report_reads))
            query = "Moje prijave"
            run_turn(query, action: "report_status", topic: "report", operation: "start", entities: { query: })
            run_turn("Koliko košta parking?", topic: "parking", operation: "switch", entities: { query: "Koliko košta parking?" })
            suspended = @state.fetch("suspended_task")
            assert suspended.fetch("entities").frozen?
            assert suspended.fetch("entity_provenance").frozen?

            result = run_turn("nastavi", action: "help", operation: "clarify", clarification: true)

            assert_equal "unsupported", result.resolution
            assert_equal "report_status", @state.fetch("active_task")
            assert_nil @state.fetch("suspended_task")
            assert_equal(%w(report parking report), @reads.map { |read| read.fetch(:topic) })
            assert_equal({ "query" => query }, @reads.last.fetch(:entities))
            assert_equal({ "query" => query }, suspended.fetch("entities"))
            assert_equal({ "query" => "citizen" }, suspended.fetch("entity_provenance"))
            assert_empty @handoffs
          end

          def test_public_evidence_followups_preserve_pending_task_without_another_read
            @read_result = Contracts::ReadResult.new(
              status: "stale",
              facts: [
                fact("id" => "notice:a", "source_label" => "Water operator", "checked_at" => "2026-09-01T08:00:00Z",
                     "observed_at" => "2026-09-02", "starts_at" => "2026-09-09T00:00:00Z", "ends_at" => "2026-09-10T00:00:00Z"),
                fact("id" => "notice:b", "source_label" => "Water operator", "checked_at" => "2026-09-03T08:00:00Z",
                     "observed_at" => "2026-09-04", "starts_at" => "2026-09-14T00:00:00Z", "ends_at" => "2026-09-15T00:00:00Z")
              ], coverage: { "area_slugs" => ["dvorovi"] }, validity: { "starts_at" => "2026-09-08T00:00:00Z", "ends_at" => "2026-09-08T23:59:59Z" }
            )
            run_turn("Voda u Dvorovima", topic: "water", operation: "start", entities: { area_query: "Dvorovi" })
            @state = JSON.parse(JSON.generate(@state))
            @state["pending_slot"] = "time_expression"
            @state["clarification_count"] = 1
            retained_expiry = @state.dig("prior_evidence", "expires_at")
            reads = @reads.length

            source = @runner.prior_evidence_follow_up(kind: "source", state: @state, context: @context, message: Message.new(text: "Odakle ti to?", dialogue_location: nil))
            assert_includes source.reply.text, "Posljednji sačuvani"
            assert_includes source.reply.text, "zastario"
            assert_equal reads, @reads.length
            assert_equal "time_expression", source.state.fetch("pending_slot")
            assert_equal "water", source.state.fetch("topic")
            assert_equal 1, source.state.fetch("clarification_count")
            assert_equal retained_expiry, source.state.dig("prior_evidence", "expires_at")

            date = @runner.prior_evidence_follow_up(kind: "date", state: source.state, context: @context, message: Message.new(text: "Za koji datum važi?", dialogue_location: nil))
            # Stored evidence stays ISO 8601 (asserted below); the citizen reads
            # Europe/Sarajevo wall-clock times, so the UTC windows shift by +2.
            requested_line = date.reply.text.lines.first.chomp
            assert_equal "Traženi datum ili period: 8.9.2026. u 02:00; 9.9.2026. u 01:59", requested_line
            refute_includes requested_line, "9.9.2026. u 02:00"
            refute_includes requested_line, "14.9.2026."
            assert_includes date.reply.text, "Podatak 1 (Water operator) — važenje: 9.9.2026. u 02:00; 10.9.2026. u 02:00"
            assert_includes date.reply.text, "Podatak 1 (Water operator) — datum zapažanja: 2.9.2026."
            assert_includes date.reply.text, "Podatak 2 (Water operator) — važenje: 14.9.2026. u 02:00; 15.9.2026. u 02:00"
            assert_includes date.reply.text, "Podatak 2 (Water operator) — vrijeme provjere izvora: 3.9.2026. u 10:00"
            refute_match(/\d{4}-\d{2}-\d{2}/, date.reply.text)
            assert_equal "2026-09-09T00:00:00Z", date.state.dig("prior_evidence", "facts", 0, "starts_at")
            assert_equal "2026-09-03T08:00:00Z", date.state.dig("prior_evidence", "facts", 1, "checked_at")
            assert_equal reads, @reads.length
          end

          def test_disagreement_is_guidance_not_a_write_or_authoritative_correction
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact], coverage: { "area_slugs" => ["dvorovi"] })
            run_turn("Voda", topic: "water", operation: "start", entities: { area_query: "Dvorovi" })

            result = @runner.prior_evidence_follow_up(
              kind: "disagreement", state: @state, context: @context,
              message: Message.new(text: "Nije tako kod mene.", dialogue_location: nil)
            )
            assert_equal "handoff", result.resolution
            assert result.handoff_offered
            refute result.handoff_completed
            assert_includes result.reply.text, "/mi/prijavi"
          end

          def test_missing_evidence_returns_clarification_without_replacing_pending_task
            @state = JSON.parse(JSON.generate(@state))
            @state.merge!("active_task" => "ask_information", "topic" => "water", "pending_slot" => "area_query", "clarification_count" => 1)

            result = @runner.prior_evidence_follow_up(
              kind: "source", state: @state, context: @context,
              message: Message.new(text: "Odakle ti to?", dialogue_location: nil)
            )

            assert_equal "clarification", result.resolution
            assert_includes result.reply.text, "Nemam više provjerljiv"
            assert_equal "ask_information", result.state.fetch("active_task")
            assert_equal "area_query", result.state.fetch("pending_slot")
            assert_equal 1, result.state.fetch("clarification_count")
          end

          def test_member_evidence_requires_current_same_fact_read
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: %w(neighborhood_reads))
            board = fact(id: "komsiluk_post:1", source_id: "komsiluk_post:1", source_label: "Komšiluk board", text: "Private board title")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [board], coverage: { "visibility" => "member_board", "area_slugs" => ["dvorovi"] })
            run_turn("Tabla", action: "neighborhood_information", topic: "neighborhood", operation: "start", entities: { area_slug: "dvorovi" })
            @read_result = Contracts::ReadResult.new(status: "not_authorized")
            @state = JSON.parse(JSON.generate(@state))
            @state["pending_slot"] = "query"
            @state["clarification_count"] = 1

            result = @runner.prior_evidence_follow_up(kind: "source", state: @state, context: @context, message: Message.new(text: "Odakle ti to?", dialogue_location: nil))
            assert_includes result.reply.text, "bez trenutne provjere pristupa"
            refute_includes result.reply.text, "Komšiluk board"
            assert_equal({ "area_slug" => "dvorovi" }, @reads.last.fetch(:entities))
            assert_equal "query", result.state.fetch("pending_slot")
            assert_equal 1, result.state.fetch("clarification_count")
            assert_nil result.state.fetch("prior_evidence")
          end

          def test_member_source_failure_returns_the_private_safe_response_without_old_metadata
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: %w(neighborhood_reads))
            board = fact(id: "komsiluk_post:1", source_id: "komsiluk_post:1", source_label: "Board source", text: "Private board title")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [board], coverage: { "visibility" => "member_board", "area_slugs" => ["dvorovi"] })
            run_turn("Tabla", action: "neighborhood_information", topic: "neighborhood", operation: "start", entities: { area_slug: "dvorovi" })
            @read_result = Contracts::ReadResult.new(status: "unavailable")

            result = @runner.prior_evidence_follow_up(kind: "source", state: @state, context: @context, message: Message.new(text: "Odakle ti to?", dialogue_location: nil))

            assert_includes result.reply.text, "bez trenutne provjere pristupa"
            refute_includes result.reply.text, "Board source"
            refute_includes result.reply.text, "Private board title"
          end

          def test_member_evidence_refreshes_only_same_area_and_retained_facts
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: %w(neighborhood_reads))
            original = fact(id: "komsiluk_post:1", source_id: "komsiluk_post:1", source_label: "Board source")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [original], coverage: { "visibility" => "member_board", "area_slugs" => ["dvorovi"] })
            run_turn("Tabla", action: "neighborhood_information", topic: "neighborhood", operation: "start", entities: { area_slug: "dvorovi" })
            extra = fact(id: "komsiluk_post:2", source_id: "komsiluk_post:2", source_label: "Other board source")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [original, extra], coverage: { "visibility" => "member_board", "area_slugs" => ["dvorovi"] })

            result = @runner.prior_evidence_follow_up(kind: "source", state: @state, context: @context, message: Message.new(text: "Odakle ti to?", dialogue_location: nil))

            assert_equal ["komsiluk_post:1"], (result.state.dig("prior_evidence", "facts").map { |item| item.fetch("id") })
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [original], coverage: { "visibility" => "member_board", "area_slugs" => ["ledinci"] })
            unavailable = @runner.prior_evidence_follow_up(
              kind: "source", state: result.state, context: @context,
              message: Message.new(text: "Odakle ti to?", dialogue_location: nil)
            )
            assert_includes unavailable.reply.text, "bez trenutne provjere pristupa"
          end

          def test_current_stale_member_evidence_uses_current_authorized_wording_for_every_followup
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: %w(neighborhood_reads))
            board = fact("id" => "komsiluk_post:1", "source_id" => "komsiluk_post:1", "source_label" => "Board source",
                         "checked_at" => "2026-09-01T08:00:00Z")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [board], coverage: { "visibility" => "member_board", "area_slugs" => ["dvorovi"] })
            run_turn("Tabla", action: "neighborhood_information", topic: "neighborhood", operation: "start", entities: { area_slug: "dvorovi" })
            @read_result = Contracts::ReadResult.new(status: "stale", facts: [board], coverage: { "visibility" => "member_board", "area_slugs" => ["dvorovi"] })

            source = @runner.prior_evidence_follow_up(kind: "source", state: @state, context: @context, message: Message.new(text: "Odakle ti to?", dialogue_location: nil))
            date = @runner.prior_evidence_follow_up(kind: "date", state: source.state, context: @context, message: Message.new(text: "Za koji datum važi?", dialogue_location: nil))
            disagreement = @runner.prior_evidence_follow_up(
              kind: "disagreement", state: date.state, context: @context,
              message: Message.new(text: "Nije tako kod mene.", dialogue_location: nil)
            )

            [source, date, disagreement].each do |result|
              assert_includes result.reply.text.downcase, "trenutno ovlašteno čitanje"
              assert_includes result.reply.text, "zastario"
              refute_includes result.reply.text, "Posljednji sačuvani"
            end
            assert_includes date.reply.text, "važenje nije potvrđeno"
          end

          def test_exact_cyrillic_and_english_evidence_followups_choose_their_locale
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact], coverage: { "area_slugs" => ["dvorovi"] })
            run_turn("Voda", topic: "water", operation: "start", entities: { area_query: "Dvorovi" })

            cyrillic = @runner.prior_evidence_follow_up(kind: "source", state: @state, context: @context, message: Message.new(text: "Одакле ти то?", dialogue_location: nil))
            assert_includes cyrillic.reply.text, "Посљедњи"
            english = @runner.prior_evidence_follow_up(
              kind: "source", state: cyrillic.state, context: @context,
              message: Message.new(text: "What is the source?", dialogue_location: nil)
            )
            assert_includes english.reply.text, "The last retained"
          end

          def test_latin_followup_resets_cyrillic_active_locale_but_preserves_suspended_locale_and_uses_it_for_read
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: %w(neighborhood_reads))
            board = fact(id: "komsiluk_post:1", source_id: "komsiluk_post:1", source_label: "Board source")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [board], coverage: { "visibility" => "member_board", "area_slugs" => ["dvorovi"] })
            run_turn("Табла", action: "neighborhood_information", topic: "neighborhood", operation: "start", locale: "sr-Cyrl", entities: { area_slug: "dvorovi" })
            @state = JSON.parse(JSON.generate(@state))
            @state["suspended_task"] = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "registration", "topic" => "account", "pending_slot" => "query", "locale" => "sr-Cyrl"
            )

            result = @runner.prior_evidence_follow_up(kind: "source", state: @state, context: @context, message: Message.new(text: "Odakle ti to?", dialogue_location: nil))

            assert_equal "sr", result.state.fetch("locale")
            assert_equal "sr-Cyrl", result.state.dig("suspended_task", "locale")
            assert_equal "sr", @reads.last.fetch(:locale)
            assert_includes result.reply.text, "Sačuvala sam"
          end

          def test_neighborhood_to_lamp_report_preserves_area_without_granting_membership
            run_turn("Objave na tabli komšiluka", action: "neighborhood_information", topic: "neighborhood", operation: "start")
            @read_result = Contracts::ReadResult.new(status: "not_authorized")
            board = run_turn("Ledinci", action: "neighborhood_information", entities: { area_query: "Ledinci" })
            assert_equal "handoff", board.resolution
            assert_equal "neighborhood_information", @reads.last[:action]
            refute @reads.last[:context].allows?("neighborhood_reads")
            report = run_turn("Hoću prijaviti pokvarenu lampu", action: "report_problem", topic: "roads", operation: "switch", entities: { description: "Pokvarena lampa" })
            assert_equal "Ledinci", @state["entities"]["area_query"]
            assert_equal "handoff", report.resolution
            assert_nil report.reply.report
          end

          def test_fresh_report_does_not_inherit_a_previous_neighborhood_lookup
            run_turn("Pokaži Ledince", action: "choose_area", topic: "neighborhood", operation: "start", entities: { area_query: "Ledinci" })
            @reads.clear
            report = run_turn("Nova prijava: pokvarena lampa", action: "report_problem", topic: "roads", operation: "start", entities: { description: "Pokvarena lampa" })

            assert_equal "clarification", report.resolution
            assert_equal "area_query", @state["pending_slot"]
            assert_equal "Pokvarena lampa", @state.dig("entities", "description")
            refute @state["entities"].has_key?("area_query")
            refute @state["entity_provenance"].has_key?("area_query")
            assert_nil @state["suspended_task"]
            assert_nil report.reply.report
            assert_empty @reads
            refute report.handoff_completed
          end

          def test_public_area_post_assignment_and_preferences_are_distinct_steps
            public_area = run_turn("Koji je ovo komšiluk?", action: "choose_area", topic: "neighborhood", operation: "start", entities: { area_query: "Ledinci" })
            assert_equal "choose_area", @reads.last[:action]
            assert_equal "local_area_guidance", public_area.reply.answer_intent
            assert_empty @handoffs
            post = run_turn("Želim objavu", action: "neighborhood_post", topic: "neighborhood", operation: "switch")
            assert_equal "handoff", post.resolution
            assert_includes post.reply.text, "ništa nije objavljeno"
            @state = StateStore.new.empty_state(@context)
            run_turn("Promijeni obavještenja", action: "preferences", topic: "account", operation: "start")
            assert_equal "preferences", @handoffs.last[:action]
          end

          def test_account_area_selection_uses_registration_handoff_without_a_public_read
            result = run_turn(
              "Izaberi moj komšiluk",
              action: "choose_area",
              topic: "account",
              operation: "start",
              entities: { area_query: "Ledinci" }
            )

            assert_equal "handoff", result.resolution
            assert_equal "choose_area", @handoffs.last[:action]
            assert_empty @reads
            assert_equal false, result.handoff_completed
            assert_equal "setup", result.reply.answer_intent
          end

          def test_account_area_selection_without_area_does_not_add_public_lookup_clarification
            result = run_turn("Podesi moj komšiluk", action: "choose_area", topic: "account", operation: "start")

            assert_equal "handoff", result.resolution
            assert_equal "choose_area", @handoffs.last[:action]
            assert_empty @reads
          end

          def test_account_area_selection_preserves_backend_completion
            @handoff_result = Contracts::HandoffResult.new(
              account_state: "registered", next_step: "area_selected",
              destination: "/mi/komsiluk", completed: true
            )

            result = run_turn("Podesi moj komšiluk", action: "choose_area", topic: "account", operation: "start")

            assert_equal "answered", result.resolution
            assert_equal true, result.handoff_completed
            assert_equal "setup", result.reply.answer_intent
          end

          def test_explicit_account_area_change_uses_registration_handoff_and_round_trips_state
            result = run_turn("Promijeni moj komšiluk", action: "change_area", topic: "account", operation: "start")

            assert_equal "handoff", result.resolution
            assert_equal "change_area", @handoffs.last[:action]
            assert_equal false, result.handoff_completed
            assert_equal "setup", result.reply.answer_intent
            assert_empty @reads

            serialized = JSON.parse(JSON.generate(@state))
            assert_equal "change_area", serialized.fetch("active_task")
            assert_equal serialized, StateStore.new.validate(context: @context, state: serialized)
          end

          def test_secondary_account_area_change_is_preserved_and_resumes_through_registration
            first = run_turn(
              "Parking, a poslije promijeni moj komšiluk",
              topic: "parking",
              operation: "start",
              secondary: { action: "change_area", topic: "account" }
            )

            assert_equal "change_area", @state.dig("suspended_task", "active_task")
            assert_equal "account", @state.dig("suspended_task", "topic")
            assert_includes first.reply.text, "nastavi"

            reads_before_resume = @reads.size
            resumed = run_turn("nastavi", action: "help", clarification: true)
            assert_equal "handoff", resumed.resolution
            assert_equal "change_area", @handoffs.last[:action]
            assert_equal reads_before_resume, @reads.size
          end

          def test_change_area_cannot_bypass_cancellation_or_credential_guards
            cancelled = run_turn("Odustani", action: "change_area", topic: "account", operation: "cancel")
            assert_equal "cancelled", cancelled.resolution
            assert_empty @handoffs

            protected = run_turn("Moj kod je 123456", action: "change_area", topic: "account", operation: "start")
            assert_equal "unsupported", protected.resolution
            assert_empty @handoffs
          end

          def test_explicit_own_latest_report_reads_without_reference_and_drops_old_reference
            run_turn("Status prijave", action: "report_status", topic: "report", operation: "start", entities: { reference: "MI-OLD" })
            @reads.clear
            answer = run_turn("Šta je s mojom posljednjom prijavom?", action: "report_status", topic: "report")

            assert_equal "unsupported", answer.resolution
            assert_equal 1, @reads.length
            assert_equal "report_status", @reads.last.fetch(:action)
            assert_equal "Šta je s mojom posljednjom prijavom?", @reads.last.fetch(:entities).fetch("query")
            refute @reads.last.fetch(:entities).has_key?("reference")
            refute @state.fetch("entities").has_key?("reference")
            refute @reads.last.fetch(:context).allows?("own_report_reads")
          end

          def test_own_reports_still_respect_port_denial_and_vague_status_still_asks_reference
            @read_result = Contracts::ReadResult.new(status: "not_authorized")
            @handoff_result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "sign_in", destination: "/users/sign_in")
            denied = run_turn("Moje prijave", action: "report_status", topic: "report", operation: "start")
            assert_equal "handoff", denied.resolution
            refute denied.handoff_completed
            assert_equal "Moje prijave", @reads.last.fetch(:entities).fetch("query")
            assert_equal "sign_in", @handoffs.last.fetch(:action)
            assert_includes denied.reply.text, "/users/sign_in"
            refute_includes denied.reply.text, "pristup komšiluku"
            @read_result = Contracts::ReadResult.new(status: "empty")
            resumed = run_turn("nastavi", action: "report_status", topic: "report")
            assert_equal "unsupported", resumed.resolution
            assert_equal "Moje prijave", @reads.last.fetch(:entities).fetch("query")
            @state = StateStore.new.empty_state(@context)
            @reads.clear
            vague = run_turn("Status prijave", action: "report_status", topic: "report", operation: "start")
            assert_equal "clarification", vague.resolution
            assert_equal "reference", @state["pending_slot"]
            assert_empty @reads
          end

          def test_unknown_area_action_keeps_safe_public_lookup_fallback
            result = run_turn(
              "Koji je ovo kraj?",
              action: "choose_area",
              topic: "unknown",
              operation: "start",
              entities: { area_query: "Ledinci" }
            )

            assert_equal "choose_area", @reads.last[:action]
            assert_empty @handoffs
            assert_equal "unsupported", result.resolution
          end

          def test_negated_profile_request_does_not_enter_account_handoff
            run_turn("Ne mijenjaj moj profil, samo objasni opcije", action: "ask_information", topic: "account", operation: "start")

            assert_empty @handoffs
          end

          def test_cancellation_clears_active_suspended_entities_and_draft
            run_turn("parking", topic: "parking", operation: "start")
            run_turn("registracija", action: "registration", topic: "account", operation: "switch")
            result = run_turn("Odustani", action: "cancel", operation: "cancel")
            assert_equal "cancelled", result.resolution
            assert_nil @state["active_task"]
            assert_nil @state["suspended_task"]
            assert_nil @state["draft"]
            assert_empty @state["entities"]
          end

          def test_clarification_is_bounded_and_keeps_specific_next_step
            2.times do
              result = run_turn("?", action: "help", clarification: true)
              assert_equal "clarification", result.resolution
            end
            2.times do
              result = run_turn("?", action: "help", clarification: true)
              assert_equal "handoff", result.resolution
              assert_includes result.reply.text, "/pages/pomoc"
              assert_equal 2, @state["clarification_count"]
            end
          end

          def test_adapter_ambiguity_is_bounded_even_when_each_turn_has_an_area_candidate
            [%w(choose_area neighborhood), %w(ask_information waste)].each do |action, topic|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_name_ambiguous"])
              ["Centar", "Centar", "U centru"].each_with_index do |area, index|
                result = run_turn(area, action:, topic:, operation: index.zero? ? "start" : "continue", entities: { area_query: area })

                assert_equal index < 2 ? "clarification" : "handoff", result.resolution
                assert_equal [index + 1, 2].min, @state["clarification_count"]
                assert_equal "area_query", @state["pending_slot"]
                assert_includes result.reply.text, "/pages/pomoc" if index == 2
                refute result.handoff_completed
              end
              assert_empty @handoffs
            end
          end

          def test_resolved_adapter_reply_clears_the_ambiguity_before_a_permission_handoff
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_name_ambiguous"])
            2.times do |index|
              run_turn("Centar", action: "neighborhood_information", topic: "neighborhood", operation: index.zero? ? "start" : "continue", entities: { area_query: "Centar" })
            end
            @read_result = Contracts::ReadResult.new(status: "not_authorized")
            result = run_turn("Ledinci", action: "neighborhood_information", topic: "neighborhood", entities: { area_query: "Ledinci" })

            assert_equal "handoff", result.resolution
            assert_nil @state["pending_slot"]
            assert_equal 0, @state["clarification_count"]
            assert_includes result.reply.text, "/mi/moj-nalog"
            refute result.handoff_completed
          end

          def test_typed_uncertain_correction_repairs_without_replaying_completed_task
            suspended = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "registration",
              "topic" => "account"
            )
            @state = @state.merge(
              "active_task" => "report_problem",
              "topic" => "waste",
              "entities" => { "description" => "Smeće nije odvezeno", "area_query" => "Dvorovi", "address" => "Glavna 1" },
              "entity_provenance" => { "description" => "citizen", "area_query" => "citizen", "address" => "citizen" },
              "draft" => { "reference" => "r" * 16, "revision" => 1, "expires_at" => NOW.to_f + 60 },
              "suspended_task" => suspended
            )

            result = run_turn(
              "Ne, ispravi mjesto",
              action: "report_problem",
              topic: "waste",
              operation: "correct",
              clarification: true,
              entities: { street: "Svetog Save" }
            )

            assert_equal "clarification", result.resolution
            assert_includes result.reply.text, "Šta treba da ispravim"
            assert_equal "report_problem", @state["active_task"]
            assert_equal "waste", @state["topic"]
            assert_equal "Svetog Save", @state.dig("entities", "street")
            assert_equal "corrected", @state.dig("entity_provenance", "street")
            assert_equal "Dvorovi", @state.dig("entities", "area_query")
            assert_equal "registration", @state.dig("suspended_task", "active_task")
            assert_nil @state["draft"]
            assert_equal "query", @state["pending_slot"]
            # Task 4: an explicit repair is the citizen recovering from OUR
            # misunderstanding. Charging it to the clarification budget is what
            # turned "Rekla sam ti već" into a handoff dead end (a8c07 t4).
            assert_equal 0, @state["clarification_count"]
            assert_empty @reads
            assert_empty @handoffs

            # Repeated repairs still escalate to the support handoff; the
            # counter now starts AT the repair instead of inheriting what the
            # citizen already spent answering slot questions, so it takes one
            # more repair to get there.
            second = run_turn("I dalje ispravi", action: "report_problem", topic: "waste", operation: "correct", clarification: true)
            assert_equal "clarification", second.resolution
            third = run_turn("Još jednom", action: "report_problem", topic: "waste", operation: "correct", clarification: true)
            assert_equal "clarification", third.resolution
            fourth = run_turn("Opet ispravi", action: "report_problem", topic: "waste", operation: "correct", clarification: true)
            assert_equal "handoff", fourth.resolution
            assert_includes fourth.reply.text, "/pages/pomoc"
            assert_equal 2, @state["clarification_count"]
            assert_equal "registration", @state.dig("suspended_task", "active_task")
            assert_empty @reads
            assert_empty @handoffs
          end

          def test_typed_uncertain_safety_keeps_safety_precedence
            before = @state
            result = run_turn(
              "Opasno je",
              action: "safety",
              operation: "correct",
              clarification: true,
              secondary: { action: "change_area", topic: "account" }
            )

            assert_equal Resolution::SAFETY_GUIDANCE, result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.safety", locale: "sr")
            assert_equal "safety", result.reply.answer_intent
            assert_equal before, @state
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.resume_offer", locale: :sr)
            assert_empty @reads
            assert_empty @handoffs
          end

          def test_typed_safety_preserves_valid_existing_and_suspended_tasks_without_resume_copy
            suspended = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "registration", "topic" => "account"
            )
            @state = @state.merge(
              "active_task" => "report_problem", "topic" => "waste",
              "entities" => { "description" => "Pokvarena lampa" },
              "entity_provenance" => { "description" => "citizen" },
              "suspended_task" => suspended
            )
            @state = StateStore.new.validate(context: @context, state: @state)
            before = @state

            result = run_turn(
              "Опасно је",
              action: "safety",
              operation: "switch",
              locale: "sr-Cyrl",
              secondary: { action: "change_area", topic: "account" }
            )

            assert_equal Resolution::SAFETY_GUIDANCE, result.resolution
            assert_equal before, @state
            assert_equal I18n.t("decidim.bih.dialogue.safety", locale: :"sr-Cyrl"), result.reply.text
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.resume_offer", locale: :sr)
            assert_empty @reads
            assert_empty @handoffs
          end

          def test_numeric_followup_keeps_cyrillic_script
            run_turn("Вода?", topic: "water", operation: "start", locale: "sr-Cyrl")
            reply = run_turn("1", clarification: true, locale: "sr")
            assert_equal "sr-Cyrl", @state["locale"]
            assert_match(/\p{Cyrillic}/, reply.reply.text)
          end

          def test_continue_and_correction_cannot_switch_to_a_model_proposed_different_action
            run_turn("Prijavljujem lampu", action: "report_problem", topic: "roads", operation: "start", entities: { description: "Lampa" })
            %w(continue correct clarify).each do |operation|
              result = run_turn("Dvorovi", action: "registration", operation:, entities: { area_query: "Dvorovi" })
              assert_equal "report_problem", @state["active_task"]
              refute result.handoff_completed
            end
            assert_empty @handoffs
          end

          def test_model_canonical_area_is_not_accepted_and_explicit_dates_are_validated
            run_turn("Ima li vode?", topic: "water", operation: "start", entities: { area_slug: "komsiluk-invented" })
            assert_empty @state["entities"]
            run_turn("Dvorovi 2026-09-06", entities: { area_query: "Dvorovi", date: "2026-09-06" })
            assert_equal "2026-09-06", @reads.last[:entities]["date"]
            run_turn("Sutra", operation: "correct", entities: { time_expression: "sutra" })
            refute @state["entities"].has_key?("date")
          end

          def test_multiintent_retains_one_distinct_domain_task_and_control_secondary_is_never_resumed
            result = run_turn("Parking pa registracija", topic: "parking", operation: "start", secondary: { action: "registration", topic: "account" })
            assert_equal "registration", @state.dig("suspended_task", "active_task")
            assert_includes result.reply.text, "nastavi"
            run_turn("nastavi", action: "help", clarification: true)
            assert_equal "registration", @handoffs.last[:action]
            @state = StateStore.new.empty_state(@context)
            run_turn("Parking", topic: "parking", operation: "start", secondary: { action: "cancel", topic: "unknown" })
            assert_nil @state["suspended_task"]
          end

          def test_expired_state_and_invalid_suspended_control_cannot_execute_reads
            @state = @state.merge("expires_at" => NOW.to_f)
            assert_raises(Contracts::Invalid) { run_turn("nastavi") }
            assert_empty @reads
            @state = StateStore.new.empty_state(@context)
            @state["suspended_task"] = @state.slice(*StateStore::TASK_KEYS).merge("active_task" => "safety")
            assert_raises(Contracts::Invalid) { run_turn("nastavi") }
          end

          def test_supplied_credentials_never_reach_either_port_or_state
            result = run_turn("Moj kod je 123456", action: "registration", topic: "account", entities: { description: "123456" })
            assert_equal "unsupported", result.resolution
            assert_empty @reads
            assert_empty @handoffs
            assert_empty @state["entities"]
            assert_raises(Contracts::Invalid) { run_turn("hello", entities: { description: "password: private" }) }
          end

          def test_expired_or_unsafe_handoffs_cannot_be_offered_or_count_as_completion
            @handoff_result = Contracts::HandoffResult.new(account_state: "registered", next_step: "registered", destination: "/mi/account", expires_at: NOW, completed: true)
            result = run_turn("registracija", action: "registration", topic: "account", operation: "start")
            refute result.handoff_offered
            refute result.handoff_completed
            assert_equal "unsupported", result.resolution
            @handoff_result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "javascript:alert(1)")
            assert_raises(Contracts::Invalid) { run_turn("registracija", action: "registration", topic: "account") }
          end

          def test_resumable_boolean_without_bound_return_contract_fails_closed
            @handoff_result = Contracts::HandoffResult.new(
              account_state: "registered",
              next_step: "registered",
              destination: "/mi/account",
              expires_at: NOW + 60,
              resume_supported: true
            )
            assert_raises(Contracts::Invalid) { run_turn("registracija", action: "registration", operation: "start") }
          end

          def test_fact_sources_scope_and_times_are_rendered_without_model_rewriting
            @read_result = Contracts::ReadResult.new(
              status: "ok",
              facts: [fact],
              source: { id: "water_operator", url: "https://operator.example/notice" },
              checked_at: NOW - 30,
              coverage: { area_slugs: ["dvorovi"] },
              validity: { starts_at: "2026-09-06T08:00:00+02:00" }
            )
            result = run_turn("Voda u Dvorovima", topic: "water", operation: "start", entities: { area_query: "Dvorovi" })
            assert_equal ["notice:1"], result.fact_ids
            # Scope and check times are rendered deterministically for humans in
            # Europe/Sarajevo (NOW is 14:00 there); nothing is paraphrased.
            # The coverage line names a place, never the "dvorovi" area slug it came from.
            ["Reviewed", "water_operator", "Dvorovi", "6.9.2026. u 08:00"].each { |value| assert_includes result.reply.text, value }
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.checked_at", locale: :sr, time: "danas u 13:59")
            refute_includes result.reply.text, (NOW - 30).iso8601
          end

          def test_fact_identifiers_and_provenance_are_required_and_unique
            [fact(id: ""), fact(id: "not stable"), fact(kind: "not stable"), fact(source_id: ""), fact(source_id: "not stable"), fact(text: ""), 42].each do |invalid|
              @read_result = Contracts::ReadResult.new(status: "ok", facts: [invalid], source: [])
              assert_raises(Contracts::Invalid) { run_turn("Parking", topic: "parking", operation: "start") }
            end
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact, fact])
            assert_raises(Contracts::Invalid) { run_turn("Parking", topic: "parking", operation: "start") }
          end

          def test_empty_unavailable_unreviewed_and_stale_never_assert_operational_service
            { "empty" => "unsupported", "unavailable" => "source_unavailable", "unreviewed" => "source_unavailable", "stale" => "source_unavailable" }.each do |status, expected|
              @read_result = Contracts::ReadResult.new(status:, source: { id: "operator" }, coverage: { area_slugs: ["dvorovi"] })
              result = run_turn("Voda u Dvorovima", topic: "water", operation: "start", entities: { area_query: "Dvorovi" })
              assert_equal expected, result.resolution
              assert_includes result.reply.text, "operator"
              assert_includes result.reply.text, "Dvorovi"
              assert_empty result.fact_ids
            end
          end

          def test_duplicate_lookup_has_one_finalization_and_no_receipt
            run_turn("Parking", topic: "parking", operation: "start")
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(id: "public_report:1", text: "Moguća slična prijava")])
            result = run_turn(
              "Prijavi lampu odavde",
              action: "report_problem",
              topic: "roads",
              operation: "switch",
              entities: { description: "Lampa" },
              location: { latitude: 44.7, longitude: 19.2 }
            )
            assert_equal 0, result.reply.text.scan("Sačuvala sam").size, "completed parking lookup is not saved report work"
            assert_equal ["public_report:1"], result.fact_ids
            assert_nil result.reply.report
            assert_equal "handoff", result.resolution
          end

          def test_known_missing_slot_uses_procedure_specific_clarification_and_pending_followup
            run_turn("Parking?", topic: "parking", operation: "start")
            report = run_turn(
              "Smeće nije odvezeno",
              action: "report_problem",
              topic: "waste",
              operation: "start",
              entities: { description: "Smeće nije odvezeno" },
              clarification: true
            )
            assert_equal "clarification", report.resolution
            assert_equal "report_problem", @state["active_task"]
            assert_equal "area_query", @state["pending_slot"]
            assert_includes report.reply.text, "naselju ili ulici"

            @state = StateStore.new.empty_state(@context)
            water = run_turn(
              "Ima li prekida vode?",
              topic: "water",
              operation: "start",
              clarification: true
            )
            assert_equal "area_query", @state["pending_slot"]
            assert_includes water.reply.text, "naselju ili ulici"

            followup = run_turn("?", action: "help", operation: "clarify", clarification: true)
            assert_equal "area_query", @state["pending_slot"]
            assert_equal I18n.t("decidim.bih.dialogue.ask_area_query_again", locale: "sr"), followup.reply.text
            refute_includes followup.reply.text, "prijaviti gradski problem"
          end

          def test_generic_understanding_clarification_does_not_replay_an_active_water_task
            run_turn(
              "Voda u Dvorovima danas",
              topic: "water",
              operation: "start",
              entities: { area_query: "Dvorovi", time_expression: "danas" }
            )
            @reads.clear
            @handoffs.clear

            first = run_turn("Ne razumijem", action: "help", topic: "unknown", operation: "clarify", clarification: true)

            assert_equal "clarification", first.resolution
            assert_equal "ask_information", @state["active_task"]
            assert_equal "water", @state["topic"]
            assert_equal({ "area_query" => "Dvorovi", "time_expression" => "danas" }, @state["entities"])
            assert_equal "query", @state["pending_slot"]
            assert_equal 1, @state["clarification_count"]
            assert_empty @reads
            assert_empty @handoffs
            assert_empty first.fact_ids
            assert_nil first.reply.report

            second = run_turn("Ne razumijem", action: "help", topic: "unknown", operation: "clarify", clarification: true)

            assert_equal "clarification", second.resolution
            assert_equal 2, @state["clarification_count"]
            assert_empty @reads
            assert_empty @handoffs

            third = run_turn("Ne razumijem", action: "help", topic: "unknown", operation: "clarify", clarification: true)

            assert_equal "handoff", third.resolution
            assert_includes third.reply.text, "/pages/pomoc"
            assert_empty @reads
            assert_empty @handoffs
          end

          def test_generic_understanding_clarification_does_not_execute_other_active_tasks
            [
              ["registration", "account", { "query" => "registracija" }],
              ["report_problem", "roads", { "description" => "Pokvarena rasvjeta", "area_query" => "Dvorovi" }],
              ["neighborhood_information", "neighborhood", { "area_query" => "Dvorovi" }]
            ].each do |action, topic, entities|
              @state = StateStore.new.empty_state(@context).merge(
                "active_task" => action,
                "topic" => topic,
                "entities" => entities,
                "entity_provenance" => entities.transform_values { "citizen" }
              )
              @reads.clear
              @handoffs.clear

              result = run_turn("Ne razumijem", action: "help", topic: "unknown", operation: "clarify", clarification: true)

              assert_equal "clarification", result.resolution, action
              assert_equal action, @state["active_task"]
              assert_equal topic, @state["topic"]
              assert_equal entities, @state["entities"]
              assert_empty @reads, action
              assert_empty @handoffs, action
              assert_empty result.fact_ids
              assert_nil result.reply.report
            end
          end

          def test_typed_clarification_with_valid_slots_still_runs_the_requested_read
            result = run_turn(
              "Voda u Dvorovima",
              topic: "water",
              operation: "start",
              clarification: true,
              entities: { area_query: "Dvorovi" }
            )

            assert_equal "unsupported", result.resolution
            assert_equal 1, @reads.size
            assert_equal "water", @reads.last[:topic]
            assert_equal({ "area_query" => "Dvorovi", "query" => "" }, @reads.last[:entities])
          end

          def test_explicit_suspended_task_resume_is_not_treated_as_generic_clarification
            @state = @state.merge(
              "active_task" => "ask_information",
              "topic" => "parking",
              "suspended_task" => StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge(
                "active_task" => "registration", "topic" => "account"
              )
            )

            result = run_turn("nastavi", action: "help", topic: "unknown", operation: "clarify", clarification: true)

            assert_equal "handoff", result.resolution
            assert_equal "registration", @handoffs.last[:action]
            assert_empty @reads
          end

          def test_starting_a_fresh_same_procedure_task_does_not_reuse_prior_slots
            run_turn(
              "Voda u Dvorovima",
              topic: "water",
              operation: "start",
              entities: { area_query: "Dvorovi", time_expression: "danas" }
            )

            result = run_turn("Novo pitanje o parkingu", topic: "parking", operation: "start")

            assert_equal "unsupported", result.resolution
            assert_equal "parking", @reads.last[:topic]
            assert_equal({ "query" => "Novo pitanje o parkingu" }, @reads.last[:entities])
            assert_nil @state["suspended_task"]
          end

          def test_continue_cannot_change_topic_but_correction_can
            run_turn("Parking?", topic: "parking", operation: "start")
            reads_before_conflict = @reads.size

            conflict = run_turn(
              "Voda u Dvorovima",
              topic: "water",
              operation: "continue",
              entities: { area_query: "Dvorovi" }
            )
            assert_equal "clarification", conflict.resolution
            assert_equal "parking", @state["topic"]
            assert_equal reads_before_conflict, @reads.size

            corrected = run_turn(
              "Mislila sam na vodu u Dvorovima",
              topic: "water",
              operation: "correct",
              entities: { area_query: "Dvorovi" }
            )
            assert_equal "unsupported", corrected.resolution
            assert_equal "water", @state["topic"]
            assert_equal "water", @reads.last[:topic]
          end

          def test_describing_a_generic_report_refines_topic_and_asks_only_for_place
            run_turn("Želim prijaviti problem", action: "report_problem", topic: "report", operation: "start")
            assert_equal "description", @state["pending_slot"]
            response = run_turn("Kontejner je prevrnut", action: "report_problem", topic: "waste", operation: "continue",
                                                         entities: { description: "Kontejner je prevrnut" }, clarification: true)
            assert_equal "clarification", response.resolution
            assert_equal "waste", @state["topic"]
            assert_equal "area_query", @state["pending_slot"]
            assert_equal "Kontejner je prevrnut", @state["entities"]["description"]
            located = run_turn("Primjer ulica", action: "report_problem", topic: "waste", entities: { street: "Primjer ulica" })
            assert_equal "handoff", located.resolution
            assert @state["report_handoff_offered"]
          end

          def test_new_question_saves_unfinished_report_in_place_of_an_already_answered_read
            run_turn("Parking", topic: "parking", operation: "start")
            run_turn("Prijavljujem klupu", action: "report_problem", topic: "roads", operation: "switch",
                                           entities: { description: "Slomljena klupa" })
            assert_equal "area_query", @state["pending_slot"]
            response = run_turn("Sada me zanima voda", topic: "water", operation: "switch", entities: { area_query: "Primjer" })
            assert_equal "unsupported", response.resolution
            assert_equal "water", @state["topic"]
            assert_equal "report_problem", @state.dig("suspended_task", "active_task")
            assert_equal "Slomljena klupa", @state.dig("suspended_task", "entities", "description")
            assert_equal "area_query", @state.dig("suspended_task", "pending_slot")
            run_turn("nastavi", action: "help", clarification: true)
            assert_equal "report_problem", @state["active_task"]
            assert_equal "area_query", @state["pending_slot"]
          end

          def test_correction_invalidates_dependent_location_and_time_slots
            run_turn(
              "Prijavi kvar u Dvorovima, Stara 1, 2026-09-06",
              action: "report_problem",
              topic: "roads",
              operation: "start",
              entities: {
                description: "Kvar",
                area_query: "Dvorovi",
                street: "Stara",
                address: "Stara 1",
                date: "2026-09-06"
              }
            )
            @state = @state.merge(
              "entities" => @state.fetch("entities").merge("area_slug" => "dvorovi"),
              "entity_provenance" => @state.fetch("entity_provenance").merge("area_slug" => "validated_source")
            )

            run_turn("Ne Dvorovi, Ledinci", action: "report_problem", operation: "correct", entities: { area_query: "Ledinci" })
            assert_equal "Ledinci", @state.dig("entities", "area_query")
            %w(area_slug street address).each { |key| refute @state.fetch("entities").has_key?(key) }

            run_turn("Sutra", action: "report_problem", operation: "correct", entities: { time_expression: "sutra" })
            refute @state.fetch("entities").has_key?("date")
            run_turn("2026-09-07", action: "report_problem", operation: "correct", entities: { date: "2026-09-07" })
            refute @state.fetch("entities").has_key?("time_expression")
          end

          def test_task_replacement_of_a_read_preserves_suspension_and_rejects_an_extra_secondary
            run_turn(
              "Parking pa registracija",
              topic: "parking",
              operation: "start",
              secondary: { action: "registration", topic: "account" }
            )

            result = run_turn(
              "I voda i parking",
              topic: "parking",
              secondary: { action: "ask_information", topic: "water" },
              clarification: true
            )

            assert_equal "clarification", result.resolution
            assert_equal "registration", @state.dig("suspended_task", "active_task")
            assert_equal "account", @state.dig("suspended_task", "topic")
            suspended = @state.fetch("suspended_task")

            start = run_turn("Servisne objave za Naselje Primjer", topic: "water", operation: "start", entities: { area_query: "Naselje Primjer" })
            assert_equal "unsupported", start.resolution
            assert_equal "water", @state["topic"]
            assert_equal "water", @reads.last[:topic]
            assert_equal suspended, @state["suspended_task"]
            assert_nil @state["pending_slot"]
            assert_equal 0, @state["clarification_count"]
          end

          def test_task_replacement_after_setup_keeps_one_suspension_and_never_completes_a_report
            %w(start switch).each do |operation|
              @state = StateStore.new.empty_state(@context)
              @reads.clear
              @handoffs.clear
              @handoff_result = Contracts::HandoffResult.new(account_state: "registered", next_step: "registered", destination: "/mi/moj-nalog", completed: true)
              run_turn("Opšti pregled parkinga", topic: "parking", operation: "start", entities: { area_query: "Naselje Primjer" })
              run_turn("Otvori pomoć za registraciju", action: "registration", topic: "account", operation: "switch")
              suspended = @state.fetch("suspended_task")
              @state = @state.merge("pending_slot" => "query", "clarification_count" => 2)

              result = run_turn("Nova prijava o klupi", action: "report_problem", topic: "roads", operation:, entities: { description: "Oštećena klupa" })

              assert_equal "clarification", result.resolution, operation
              assert_equal "report_problem", @state["active_task"]
              assert_equal "roads", @state["topic"]
              assert_equal "area_query", @state["pending_slot"]
              assert_equal 1, @state["clarification_count"]
              assert_equal({ "description" => "Oštećena klupa" }, @state["entities"])
              assert_equal suspended, @state["suspended_task"]
              assert_nil result.reply.report
              refute result.handoff_completed
              assert_equal 1, @handoffs.length

              handoff = run_turn("Naselje Primjer", action: "report_problem", entities: { area_query: "Naselje Primjer" })
              assert_equal "handoff", handoff.resolution
              assert_nil handoff.reply.report
              refute handoff.handoff_completed
              assert_equal suspended, @state["suspended_task"]

              resumed = run_turn("nazad", action: "help", clarification: true)
              assert_equal "unsupported", resumed.resolution
              assert_equal "parking", @state["topic"]
              assert_nil @state["suspended_task"]
              assert_equal "parking", @reads.last[:topic]
            end
          end

          def test_explicit_task_replacement_can_leave_named_or_gps_report_form_guidance
            %w(start switch).product([false, true]).each do |operation, gps_only|
              @state = StateStore.new.empty_state(@context)
              run_turn("Pomoć za registraciju", action: "registration", topic: "account", operation: "start")
              entities = { description: "Oštećen trotoar" }
              entities[:area_query] = "Naselje Primjer" unless gps_only
              location = { latitude: 44.75, longitude: 19.2 } if gps_only
              handoff = run_turn("Prijava trotoara", action: "report_problem", topic: "roads", operation: "switch", entities:, location:)
              suspended = @state.fetch("suspended_task")

              assert_equal "handoff", handoff.resolution
              assert_equal true, @state.fetch("report_handoff_offered")
              refute handoff.handoff_completed
              @state = @state.merge("pending_slot" => "query", "clarification_count" => 2)
              result = run_turn("Sada parking", topic: "parking", operation:)

              assert_equal "unsupported", result.resolution
              assert_equal "ask_information", @state.fetch("active_task")
              assert_equal "parking", @state.fetch("topic")
              assert_equal suspended, @state.fetch("suspended_task")
              assert_empty @state.fetch("entities")
              assert_nil @state.fetch("pending_slot")
              assert_equal false, @state.fetch("report_handoff_offered")
              assert_nil result.reply.report
              refute result.handoff_completed
              run_turn("nastavi", action: "help", clarification: true)
              assert_equal "registration", @state.fetch("active_task")
            end
          end

          def test_uncertain_report_correction_or_opaque_draft_keeps_handoff_task_protected
            [:correction, :draft].each do |protection|
              @state = StateStore.new.empty_state(@context)
              run_turn("Pomoć za registraciju", action: "registration", topic: "account", operation: "start")
              run_turn("Prijava trotoara", action: "report_problem", topic: "roads", operation: "switch",
                                           entities: { description: "Oštećen trotoar", area_query: "Naselje Primjer" })
              if protection == :correction
                run_turn("Pogrešno mjesto", action: "report_problem", topic: "roads", operation: "correct", clarification: true)
                assert_equal false, @state.fetch("report_handoff_offered")
              else
                @state = @state.merge("draft" => { "reference" => "d" * 16, "revision" => 1, "expires_at" => NOW.to_f + 60 })
              end
              before = @state
              result = run_turn("Sada parking", topic: "parking", operation: "switch")

              assert_equal "clarification", result.resolution
              assert_equal "report_problem", @state.fetch("active_task")
              assert_equal before.fetch("entities"), @state.fetch("entities")
              assert_equal before.fetch("suspended_task"), @state.fetch("suspended_task")
              if before.fetch("draft")
                assert_equal before.fetch("draft"), @state.fetch("draft")
              else
                assert_nil @state.fetch("draft")
              end
              assert_nil result.reply.report
              refute result.handoff_completed
            end
          end

          def test_task_replacement_keeps_active_report_post_and_opaque_draft_protected
            suspended = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge("active_task" => "registration", "topic" => "account")
            draft = { "reference" => "s" * 16, "revision" => 1, "expires_at" => NOW.to_f + 60 }
            [["report_problem", "roads", nil], ["neighborhood_post", "neighborhood", nil], ["ask_information", "parking", draft]].each do |action, topic, active_draft|
              %w(start switch).each do |operation|
                entities = { "description" => "Sačuvani probni tekst" }
                @state = StateStore.new.empty_state(@context).merge(
                  "active_task" => action, "topic" => topic, "entities" => entities,
                  "entity_provenance" => { "description" => "citizen" }, "draft" => active_draft, "suspended_task" => suspended
                )

                result = run_turn("Novo opšte pitanje o otpadu", topic: "waste", operation:)

                assert_equal "clarification", result.resolution
                assert_equal action, @state["active_task"]
                assert_equal topic, @state["topic"]
                assert_equal entities, @state["entities"]
                if active_draft
                  assert_equal active_draft, @state["draft"]
                else
                  assert_nil @state["draft"]
                end
                assert_equal suspended, @state["suspended_task"]
                assert_empty @reads
                assert_empty @handoffs
                assert_nil result.reply.report
                refute result.handoff_completed
              end
            end
          end

          def test_task_replacement_does_not_reinterpret_continuations_or_corrections
            %w(continue correct clarify).each do |operation|
              suspended = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge("active_task" => "registration", "topic" => "account")
              @state = StateStore.new.empty_state(@context).merge("active_task" => "ask_information", "topic" => "parking", "suspended_task" => suspended)

              result = run_turn("Nova prijava o klupi", action: "report_problem", topic: "roads", operation:)

              assert_equal "clarification", result.resolution
              assert_equal "ask_information", @state["active_task"]
              assert_equal "parking", @state["topic"]
              assert_equal suspended, @state["suspended_task"]
              assert_empty @reads
              assert_empty @handoffs
            end
          end

          def test_a_single_top_level_source_can_supply_per_fact_provenance
            source_free = fact.except("source_id", "source_url")
            @read_result = Contracts::ReadResult.new(
              status: "ok",
              facts: [source_free],
              source: { id: "water_operator", label: "Water operator", url: "https://operator.example/notice" }
            )

            result = run_turn("Parking", topic: "parking", operation: "start")

            assert_equal ["notice:1"], result.fact_ids
            assert_equal 1, result.reply.text.scan("Water operator").size
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Typed outcome coverage for every way a read can end without facts.
        #
        # The defect these lock down: a reply that says "Za ovo nemam provjeren
        # podatak" ("I have no verified data for this") used to finish with
        # resolution "answered", so every refusal was counted as a success in
        # ConciergeUsageAggregate and in the operator's answer-quality review.
        #
        # The distinction that must survive the fix: a scoped zero-result
        # answer — "I checked the volunteer catalogue for this komsiluk over
        # this window and there are none" — IS an answer and stays "answered".
        class EmptyReadOutcomeTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 10, 30)
          Message = Data.define(:text, :dialogue_location)

          def setup
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "b" * 64, now: NOW,
                                                     capabilities: %w(public_reads report_guidance registration_handoff))
            @state = StateStore.new.empty_state(@context)
            @read_result = Contracts::ReadResult.new(status: "empty")
            @runner = ProcedureRunner.new(
              read_port: ->(**) { @read_result },
              registration_port: ->(**) { Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "/users/sign_up") },
              destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: "/pages/pomoc" }
            )
          end

          def refusal = I18n.t("decidim.bih.dialogue.no_match", locale: "sr")

          # ---------------------------------------------------------------
          # true empty — a complete, scoped zero-result answer
          # ---------------------------------------------------------------

          def test_a_complete_zero_result_catalogue_answer_stays_answered
            @read_result = catalogue_empty_result
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal "answered", result.resolution
            refute_includes result.reply.text, refusal
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.catalog_empty_volunteer", locale: "sr")
          end

          # ---------------------------------------------------------------
          # unresolved empty — the two branches Task 9b fixed
          # ---------------------------------------------------------------

          # Branch 1: the reader said "empty" and no scoped answer could be
          # composed, so the turn fell back to the refusal.
          def test_an_empty_read_without_a_scoped_answer_is_not_answered
            @read_result = Contracts::ReadResult.new(status: "empty", source: { "id" => "platform:volunteer" })
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_includes result.reply.text, refusal
            assert_equal "unsupported", result.resolution
          end

          # Branch 2: the reader said "ok" and carried no facts at all.
          def test_an_available_read_with_no_facts_is_not_answered
            @read_result = Contracts::ReadResult.new(status: "ok", source: { "id" => "water_operator" })
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_includes result.reply.text, refusal
            assert_equal "unsupported", result.resolution
          end

          # ---------------------------------------------------------------
          # the states that must NOT be collapsed into that one label
          # ---------------------------------------------------------------

          def test_a_stale_read_with_no_facts_is_a_source_health_label
            @read_result = Contracts::ReadResult.new(status: "stale", source: { "id" => "water_operator" })
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal "source_unavailable", result.resolution
            assert Resolution.source_health?(result.resolution)
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.stale", locale: "sr")
          end

          def test_an_unreviewed_source_keeps_its_own_copy_and_a_source_health_label
            @read_result = Contracts::ReadResult.new(status: "unreviewed", source: { "id" => "water_operator" })
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal "source_unavailable", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.unreviewed", locale: "sr", url: "/pages/pomoc")
            refute_includes result.reply.text, refusal
          end

          def test_an_unavailable_source_keeps_its_own_copy_and_a_source_health_label
            @read_result = Contracts::ReadResult.new(status: "unavailable", warnings: ["read_failed"])
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal "source_unavailable", result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.unavailable", locale: "sr", url: "/pages/pomoc")
            refute_includes result.reply.text, refusal
          end

          def test_an_unauthorized_read_is_a_handoff_not_a_refusal
            @read_result = Contracts::ReadResult.new(status: "not_authorized")
            result = run_turn("Gdje je moja prijava?", topic: "report", entities: { "query" => "moja prijava" })

            assert_equal "handoff", result.resolution
            assert result.handoff_offered
            refute_includes result.reply.text, refusal
          end

          # Every one of these labels is distinct, and only the complete
          # zero-result one counts as an answered turn.
          def test_the_empty_shaped_states_stay_distinguishable
            labels = {
              complete_empty: Resolution.empty_read(complete: true),
              unresolved_empty: Resolution.empty_read(complete: false),
              stale: Resolution.empty_available_read(stale: true)
            }

            assert_equal labels.values.uniq.size, labels.size
            assert_equal [:complete_empty], (labels.select { |_, value| Resolution.succeeded?(value) }.keys)
          end

          # busy and provider_error never reach a procedure — the coordinator
          # produces them — but they must stay unresolved and outside the
          # source-health pair, or an admission refusal would read as a broken
          # city source.
          def test_busy_and_provider_error_are_unresolved_but_not_source_health
            assert Resolution.unresolved?(Resolution::BUSY)
            assert Resolution.unresolved?(Resolution::PROVIDER_UNAVAILABLE)
            refute Resolution.source_health?(Resolution::BUSY)
            assert Resolution.source_health?(Resolution::PROVIDER_UNAVAILABLE)
            refute Resolution.succeeded?(Resolution::BUSY)
          end

          # ---------------------------------------------------------------
          # one reply, ONE typed outcome
          # ---------------------------------------------------------------

          # THE defect the 14.09.2026 648-turn replay recorded (a1c05 T1,
          # a7c05 T2): a single reply opened with the "no verified data"
          # refusal and, four lines later, printed the source's own
          # checked-zero sentence. "I hold no verified record" and "I read the
          # source and it holds nothing for your area and period" are
          # different claims about the world, and the citizen could not tell
          # which one was true.
          def test_a_reply_never_carries_the_refusal_and_a_checked_zero_claim
            @read_result = checked_zero_result
            result = run_water_turn

            assert_includes result.reply.text, reviewed_empty
            refute_includes result.reply.text, refusal
          end

          # The read's own account is the answer, so it is printed once — as
          # the reply's first sentence — and not repeated in the warning block
          # underneath it.
          def test_the_checked_zero_sentence_is_printed_exactly_once
            @read_result = checked_zero_result
            result = run_water_turn

            assert_equal 1, result.reply.text.scan(reviewed_empty).length
            assert result.reply.text.start_with?(reviewed_empty), result.reply.text
          end

          # A checked zero result IS an answer: the source was read, the scope
          # is named above and nothing is missing, so it carries no next step.
          def test_a_checked_zero_read_is_answered_and_owes_no_next_step
            @read_result = checked_zero_result
            result = run_water_turn

            assert_equal "answered", result.resolution
            refute_includes result.reply.text, support_next_step
            refute_includes result.reply.text, source_next_step
          end

          # The second checked-zero code, and the one that reaches the citizen
          # when the source was read but its collected notices do not cover the
          # question. Same outcome, its own sentence.
          def test_an_unmatched_window_is_the_same_outcome_with_its_own_sentence
            @read_result = checked_zero_result(warnings: %w(source_scope_or_time_not_matched absence_not_evidence_of_normal_service))
            result = run_water_turn

            assert_equal "answered", result.resolution
            assert_includes result.reply.text, window_not_matched
            refute_includes result.reply.text, refusal
          end

          # The caveat that stops a zero result reading as "the service is
          # fine" survives the promotion — it qualifies the answer's scope and
          # is not the answer.
          def test_the_absence_caveat_survives_a_checked_zero_answer
            @read_result = checked_zero_result
            result = run_water_turn

            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_absence_not_normal_service", locale: "sr")
          end

          # A refusal with no checked-zero claim is untouched: it keeps the
          # "no verified data" sentence AND the next step R3 gave it.
          def test_a_refusal_without_a_checked_zero_claim_keeps_its_next_step
            @read_result = Contracts::ReadResult.new(status: "empty", source: { "id" => "platform:volunteer" },
                                                     warnings: ["absence_not_evidence_of_normal_service"])
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal "unsupported", result.resolution
            assert_includes result.reply.text, refusal
            assert_includes result.reply.text, support_next_step
          end

          # ---------------------------------------------------------------
          # one test per outcome — the five labels must not blur
          # ---------------------------------------------------------------

          def test_unsupported_keeps_its_label_and_its_sentence
            @read_result = Contracts::ReadResult.new(status: "empty", source: { "id" => "platform:volunteer" })
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal Resolution::UNSUPPORTED, result.resolution
            assert_includes result.reply.text, refusal
            refute_includes result.reply.text, reviewed_empty
          end

          def test_source_unavailable_keeps_its_label_and_its_sentence
            @read_result = Contracts::ReadResult.new(status: "stale", source: { "id" => "water_operator" },
                                                     warnings: ["no_matching_source_notice"])
            result = run_turn("Ima li volonterskih akcija?", topic: "volunteer", entities: { "query" => "volonterske akcije" })

            assert_equal Resolution::SOURCE_UNAVAILABLE, result.resolution
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.stale", locale: "sr")
            refute_includes result.reply.text, refusal
          end

          def test_provider_unavailable_keeps_its_label
            assert_equal "provider_unavailable", Resolution::PROVIDER_UNAVAILABLE
            assert Resolution.source_health?(Resolution::PROVIDER_UNAVAILABLE)
            refute Resolution.succeeded?(Resolution::PROVIDER_UNAVAILABLE)
          end

          def test_busy_keeps_its_label
            assert_equal "busy", Resolution::BUSY
            refute Resolution.source_health?(Resolution::BUSY)
            refute Resolution.succeeded?(Resolution::BUSY)
          end

          def test_a_checked_zero_answer_keeps_the_answered_label
            @read_result = checked_zero_result
            result = run_water_turn

            assert_equal Resolution::ANSWERED, result.resolution
            assert Resolution.succeeded?(result.resolution)
            refute Resolution.unresolved?(result.resolution)
          end

          # The five outcomes this turn can end with are pairwise distinct, and
          # exactly one of them is a success.
          def test_the_five_typed_outcomes_stay_pairwise_distinct
            labels = [Resolution.empty_read(complete: false), Resolution.empty_read(complete: false, checked_zero: true),
                      Resolution.empty_available_read(stale: true), Resolution::PROVIDER_UNAVAILABLE, Resolution::BUSY]

            assert_equal %w(unsupported answered source_unavailable provider_unavailable busy), labels
            assert_equal labels.length, labels.uniq.length
            assert_equal [Resolution::ANSWERED], (labels.select { |label| Resolution.succeeded?(label) })
          end

          private

          def run_turn(text, topic:, entities:, action: "ask_information", operation: "start", locale: "sr") # rubocop:disable Metrics/ParameterLists
            understanding = Contracts::Understanding.parse(action:, topic:, entities:, operation:, locale:, needs_clarification: false, secondary: nil)
            result = @runner.call(understanding:, state: @state, context: @context, message: Message.new(text:, dialogue_location: nil))
            @state = result.state
            result
          end

          def run_water_turn
            run_turn("Da li je voda iz slavine ispravna za piće?",
                     topic: "water",
                     entities: { "query" => "voda", "area_query" => "MZ Dašnica" })
          end

          def reviewed_empty = I18n.t("decidim.bih.dialogue.read_warning_reviewed_empty", locale: "sr")

          def window_not_matched = I18n.t("decidim.bih.dialogue.read_warning_window_not_matched", locale: "sr")

          def support_next_step = I18n.t("decidim.bih.dialogue.dead_end_support", locale: "sr", url: "/pages/pomoc")

          def source_next_step
            I18n.t("decidim.bih.dialogue.dead_end_source", locale: "sr", source: "Vodovod Bijeljina", url: "/pages/pomoc")
          end

          # The live shape from the replay: a service read whose source WAS
          # reached and reviewed, over a named area and window, holding nothing.
          def checked_zero_result(warnings: %w(no_matching_source_notice absence_not_evidence_of_normal_service))
            Contracts::ReadResult.new(
              status: "empty",
              source: { "id" => "water_operator", "label" => "Vodovod Bijeljina", "url" => "https://www.bnvodovod.com/v2/category/servisne-informacije/" },
              checked_at: NOW,
              coverage: { "area_slugs" => ["dasnica"] },
              validity: { "starts_at" => "2026-09-14T10:30:00+02:00", "ends_at" => "2026-09-14T22:30:00+02:00" },
              warnings:
            )
          end

          # The shape PublicCatalogEmptyAnswer accepts: a public catalogue read
          # that names the areas it checked and the window it checked them for.
          def catalogue_empty_result
            Contracts::ReadResult.new(
              status: "empty",
              source: { "id" => "platform:volunteer" },
              coverage: {
                "access" => "public", "complete_inventory" => false,
                "requested_area_slugs" => ["dvorovi"],
                "requested_areas" => [{ "kind" => "mz", "slug" => "dvorovi", "label" => "MZ Dvorovi" }]
              },
              validity: { "timezone" => "Europe/Sarajevo" }
            )
          end
        end
      end
    end
  end
end

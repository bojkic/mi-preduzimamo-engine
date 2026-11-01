# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class CompletionWave2Test < Minitest::Test
          Message = Data.define(:text, :dialogue_location)

          def setup
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += Dir[File.expand_path("../../../../../../config/locales/decidim_bih_dialogue*.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "e" * 64,
                                                     now: Time.utc(2026, 9, 9, 12), capabilities: %w(public_reads report_guidance registration_handoff))
            @state = StateStore.new.empty_state(@context)
            @reads = []
            @read_result = Contracts::ReadResult.new(status: "empty")
            @runner = ProcedureRunner.new(read_port: ->(**args) { @reads << args; @read_result },
                                          registration_port: ->(**) { raise "No account mutation expected" },
                                          destinations: { account: "/account", neighborhood: "/board", report: "/reports", support: "/help" })
          end

          def run_question(text, input: nil)
            input ||= Coordinator.allocate.send(:fast_understanding, text, @state)
            result = @runner.call(understanding: input, state: @state, context: @context, message: Message.new(text, nil))
            @state = result.state
            result
          end

          def test_rated_closed_questions_are_typed_reads_in_both_scripts
            {
              "KAKO DA PRIBAVIM RODNI LIST" => "ask_information",
              "КАКО ДА ПРИБАВИМ РОДНИ ЛИСТ" => "ask_information",
              "ima li nekih obavještanja na tabli mog komšiluka" => "neighborhood_information",
              "ko je predsjednik moje Mz" => "choose_area"
            }.each { |text, action| assert_equal action, CivicQuestion.classify(text).fetch(:action) }
            ["nemoj prikazati objave na tabli mog komšiluka", "objavi ovo na tabli mog komšiluka",
             "kako da pribavim rodni list i prijavi rupu", "ko je predsjednik mz Ledinci i pošalji mu poruku"].each do |text|
              assert_nil CivicQuestion.classify(text)
            end
          end

          def test_board_and_document_switches_preserve_suspended_report_and_permission_denial
            @state["active_task"] = "ask_information"
            @state["topic"] = "water"
            @state["suspended_task"] = @state.slice(*StateStore::TASK_KEYS).merge("active_task" => "report_problem", "topic" => "report")
            @read_result = Contracts::ReadResult.new(status: "not_authorized", warnings: ["neighborhood_membership_required"])
            answer = run_question("ima li nekih obavještanja na tabli mog komšiluka")
            assert_equal "neighborhood_information", @reads.last.fetch(:action)
            assert_equal "handoff", answer.resolution
            assert_equal "report_problem", @state.fetch("suspended_task").fetch("active_task")
            @read_result = Contracts::ReadResult.new(status: "empty")
            answer = run_question("KAKO DA PRIBAVIM RODNI LIST")
            assert_equal "city_service", @reads.last.fetch(:topic)
            # The fixture read carries no facts, so the turn ends with the "no verified
            # data" refusal. That is "unsupported", not "answered" (Task 9b).
            assert_equal "unsupported", answer.resolution
            assert_equal "report_problem", @state.fetch("suspended_task").fetch("active_task")
          end

          def test_mz_contact_area_followup_preserves_requested_information
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
            assert_equal "clarification", run_question("ko je predsjednik moje Mz").resolution
            assert_equal "area_query", @state["pending_slot"]
            @read_result = Contracts::ReadResult.new(status: "empty")
            run_question("Ledinci")
            assert_equal "choose_area", @reads.last.fetch(:action)
            assert_equal "ledinci", @reads.last.fetch(:entities).fetch("area_query")
            assert_equal "ko je predsjednik moje Mz", @reads.last.fetch(:entities).fetch("query")
          end

          def test_water_answer_preserves_raw_question_and_groups_only_identical_provenance
            facts = %w(Drina Sava).map.with_index do |station, index|
              { "id" => "level:#{index}", "kind" => "water_level_observation", "text" => "#{station}: #{index + 27} cm.",
                "source_id" => "water_levels", "source_label" => "Public source", "source_url" => "https://source.example/levels",
                "observed_at" => "2026-09-09T10:00:00Z", "checked_at" => "2026-09-09T11:00:00Z" }
            end
            @read_result = Contracts::ReadResult.new(status: "ok", facts:, checked_at: Time.utc(2026, 9, 9, 11), validity: { "answer_shape" => "water_level_v1" })
            input = Contracts::Understanding.parse(action: "ask_information", topic: "water_levels", entities: { "query" => "vodostaj" },
                                                   operation: "start", needs_clarification: false, secondary: nil, locale: "sr")
            answer = run_question("Da li voda raste u Drini?", input:)
            assert_equal "Da li voda raste u Drini?", @reads.last.fetch(:entities).fetch("query")
            assert_equal 1, answer.reply.text.scan("https://source.example/levels").length
            # Times are rendered for humans in Europe/Sarajevo (NOW is 9.9.2026 14:00 there).
            assert_equal 1, answer.reply.text.scan("danas u 13:00").length
            assert_equal 2, answer.reply.text.scan("danas u 12:00").length
            refute_match(/\d{4}-\d{2}-\d{2}T/, answer.reply.text)
            assert_equal 2, answer.fact_ids.length
          end

          def test_fresh_own_mz_question_does_not_reuse_previously_named_area
            run_question("ko je predsjednik MZ Ledinci")
            assert_equal "ledinci", @reads.last.fetch(:entities).fetch("area_query")
            run_question("ko je predsjednik moje MZ")
            refute @reads.last.fetch(:entities).key?("area_query")
            assert_equal "ko je predsjednik moje MZ", @reads.last.fetch(:entities).fetch("query")
          end

          def test_empty_neighborhood_summary_keeps_both_limits_in_every_locale
            @read_result = Contracts::ReadResult.new(status: "empty", coverage: { "scope" => "area_public_reports", "area_labels" => ["Ledinci"],
                                                                                 "reports" => { "area_label" => "Komšiluk 12", "starts_at" => "2026-09-02T12:00:00Z", "ends_at" => "2026-09-09T12:00:00Z" } },
                                                    warnings: %w(no_matching_public_reports no_matching_collected_notices public_reports_recent_window))
            # The window is rendered for humans in Europe/Sarajevo (NOW is 9.9.2026 14:00 there).
            window_start = { "sr" => "2.9.2026. u 14:00", "sr-Cyrl" => "2.9.2026. у 14:00", "bs" => "2.9.2026. u 14:00",
                             "hr" => "2.9.2026. u 14:00", "en" => "2 Sep 2026, 14:00" }
            Contracts::LOCALES.each do |locale|
              input = Contracts::Understanding.parse(action: "ask_information", topic: "city_service", entities: {}, operation: "start",
                                                     needs_clarification: false, secondary: nil, locale:)
              answer = run_question("summary", input:)
              assert_includes answer.reply.text, "Ledinci"
              assert_includes answer.reply.text, window_start.fetch(locale)
              refute_includes answer.reply.text, "2026-09-02T12:00:00Z"
              assert_includes answer.reply.text, "Komšiluk 12"
              @read_result.warnings.each { |key| assert_includes answer.reply.text, I18n.t("decidim.bih.dialogue.read_warning_#{key}", locale:) }
            end
          end

          def test_neighborhood_possible_relevance_is_grouped_below_area_evidence
            facts = [
              { "id" => "notice:1", "kind" => "city_service_notice", "text" => "Local source-stated coverage; facts unconfirmed", "source_id" => "notice_source",
                "coverage" => { "summary_relevance" => "area" } },
              { "id" => "notice:2", "kind" => "city_service_notice", "text" => "Place-name context only, not a circuit footprint", "source_id" => "notice_source",
                "coverage" => { "summary_relevance" => "context_only" } }
            ]
            @read_result = Contracts::ReadResult.new(status: "ok", facts:,
                                                    coverage: { "scope" => "collected_public_neighborhood_activity", "area_labels" => ["Ledinci"] },
                                                    warnings: %w(neighborhood_unlocated_notices no_area_matched_collected_notices))
            Contracts::LOCALES.each do |locale|
              input = Contracts::Understanding.parse(action: "ask_information", topic: "city_service", entities: {}, operation: "start",
                                                     needs_clarification: false, secondary: nil, locale:)
              answer = run_question("summary", input:)
              heading = I18n.t("decidim.bih.dialogue.neighborhood_uncertain_notices_heading", locale:)
              assert_operator answer.reply.text.index(facts.first.fetch("text")), :<, answer.reply.text.index(heading)
              assert_operator answer.reply.text.index(heading), :<, answer.reply.text.index(facts.last.fetch("text"))
              assert_equal 2, answer.fact_ids.length
              @read_result.warnings.each { |key| assert_includes answer.reply.text, I18n.t("decidim.bih.dialogue.read_warning_#{key}", locale:) }
            end
          end
        end
      end
    end
  end
end

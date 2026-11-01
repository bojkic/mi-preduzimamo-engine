# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "yaml"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Actual procedures/state transitions, synthetic typed reads. No model,
        # Rails, database, Redis calls or membership granted by a place name.
        class NeighborhoodProcedureTest < Minitest::Test
          Message = Data.define(:text, :dialogue_location)

          def setup
            @old_backend = I18n.backend
            @old_locales = I18n.available_locales
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(*Dir[File.expand_path("../../../../../../config/locales/decidim_bih_dialogue*.yml", __dir__)])
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "b" * 64,
                                                     now: Time.utc(2026, 9, 9, 12), capabilities: ["public_reads"])
            @state = StateStore.new.empty_state(@context)
            @reads = []
            @read_result = Contracts::ReadResult.new(status: "empty")
            @runner = ProcedureRunner.new(read_port: lambda { |**args|
              @reads << args
              @read_result
            },
                                          registration_port: ->(**) { raise "Unexpected account operation" },
                                          destinations: { report: "/mi/prijavi", account: "/mi/account", neighborhood: "/mi/komsiluk", support: "/help" })
            @temporary_path = !Decidim::Bih.respond_to?(:public_path)
            Decidim::Bih.define_singleton_method(:public_path) { |_| raise "Unconfigured path" } if @temporary_path
          end

          def teardown
            Decidim::Bih.singleton_class.send(:remove_method, :public_path) if @temporary_path
            I18n.backend = @old_backend
            I18n.available_locales = @old_locales
          end

          def test_vague_activity_typos_never_read_member_posts_even_with_wrong_model_action
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
            ["Šta se dešava u mom komšilu?", "sta ima u mom košiluku?", "Шта има у мом комшилуку?", "What is happening in my neighborhood?"].each do |text|
              @state = StateStore.new.empty_state(@context)
              result = turn(text, operation: "start")
              assert_equal "clarification", result.resolution
              assert_equal "area_query", result.state["pending_slot"]
              assert_equal "ask_information", @reads.last.fetch(:action)
              assert_equal "neighborhood", @reads.last.fetch(:topic)
              refute result.handoff_offered
              refute @reads.last.fetch(:context).allows?("neighborhood_reads")
            end
          end

          def test_area_followup_keeps_public_choice_and_public_reports_read_the_same_area
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
            turn("Šta se dešava u mom komšilu?", operation: "start")
            @read_result = Contracts::ReadResult.new(status: "empty", warnings: ["no_matching_collected_notices"])
            area = turn("U Ledincima.", entities: { area_query: "Ledinci" })
            assert_equal "answered", area.resolution
            assert_equal "Ledinci", area.state.dig("entities", "area_query")
            assert_equal "ask_information", @reads.last.fetch(:action)
            @reads.clear

            @read_result = Contracts::ReadResult.new(status: "empty", coverage: { "scope" => "area_public_reports" }, warnings: ["no_matching_public_reports"])
            result = turn("Javne prijave problema")
            assert_equal "answered", result.resolution
            assert_equal "ask_information", @reads.last.fetch(:action)
            assert_equal "neighborhood", @reads.last.fetch(:topic)
            assert_equal "Ledinci", @reads.last.dig(:entities, "area_query")
            assert_equal "Javne prijave problema", @reads.last.dig(:entities, "query")
            refute_includes result.reply.text, "/biceriseno/mapa"
            refute result.handoff_offered
          end

          def test_explicit_member_posts_still_reach_unchanged_access_guard
            ["Objave na tabli komšiluka", "Nisam prijavljen, mogu li vidjeti javne objave za Dvorove?"].each do |text|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "not_authorized")
              result = turn(text, operation: "start", entities: { area_query: "Dvorovi" })
              assert_equal "neighborhood_information", @reads.last.fetch(:action)
              refute @reads.last.fetch(:context).allows?("neighborhood_reads")
              assert_equal "handoff", result.resolution
              assert_includes result.reply.text, "odgovarajući nalog"
            end
          end

          def test_public_identity_lookup_can_reach_trusted_profile_fallback_without_area
            %w(choose_area neighborhood_information).each do |action|
              @state = StateStore.new.empty_state(@context)
              @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
              result = turn("Koji je moj komšiluk?", action:, operation: "start", entities: { query: "Koji je moj komšiluk?" })
              assert_equal "choose_area", @reads.last.fetch(:action)
              assert_equal "area_query", result.state["pending_slot"]
              assert_includes result.reply.text, "U kojem naselju"
            end
          end

          def test_explicit_public_services_then_area_keeps_public_read_and_suspended_task
            turn("Šta se dešava u mom komšilu?", operation: "start")
            @reads.clear
            suspended = StateStore.new.empty_state(@context).slice(*StateStore::TASK_KEYS).merge("active_task" => "registration", "topic" => "account")
            @state = @state.merge("suspended_task" => suspended)
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
            first = turn("Servisne informacije")
            assert_equal "ask_information", first.state["active_task"]
            assert_equal "area_query", first.state["pending_slot"]
            assert_equal suspended, first.state["suspended_task"]

            @read_result = Contracts::ReadResult.new(status: "empty", warnings: ["no_matching_collected_notices"])
            second = turn("U Ledincima.", action: "ask_information", entities: { area_query: "Ledinci" })
            assert_equal "answered", second.resolution
            assert_equal "Ledinci", @reads.last.fetch(:entities).fetch("area_query")
            assert_equal(%w(ask_information ask_information), @reads.map { |read| read.fetch(:action) })
            assert_equal suspended, second.state["suspended_task"]
            assert_nil second.state["pending_slot"]
            assert_includes second.reply.text, "Među prikupljenim javnim servisnim obavještenjima"
            assert_includes second.reply.text, "To ne znači da nema prekida"
            refute second.handoff_completed
          end

          def test_public_service_facts_use_existing_renderer_and_board_choice_still_requires_private_access
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [{ "id" => "service_event:23", "kind" => "city_service_event",
                                                                             "text" => "Synthetic reviewed notice", "source_id" => "water_service" }])
            result = turn("Servisne informacije", operation: "start", entities: { area_query: "Ledinci" })
            assert_equal "answered", result.resolution
            assert_equal ["service_event:23"], result.fact_ids
            assert_includes result.reply.text, "Synthetic reviewed notice"

            @read_result = Contracts::ReadResult.new(status: "not_authorized")
            board = turn("Objave članova", action: "neighborhood_information", operation: "switch")
            assert_equal "neighborhood_information", @reads.last.fetch(:action)
            assert_equal "handoff", board.resolution
            refute @reads.last.fetch(:context).allows?("neighborhood_reads")
          end

          def test_live_like_occupied_report_choice_and_area_survive_generic_or_mismatched_model_output
            %w(help ask_information neighborhood_information choose_area).each do |model_action|
              prime_occupied_report
              suspended = @state.fetch("suspended_task")
              @reads.clear
              @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
              first = turn("Javna obavještenja o uslugama.", action: model_action, topic: model_action == "help" ? "unknown" : "city_service",
                                                             operation: "clarify", clarification: true)
              assert_equal "area_query", first.state["pending_slot"], model_action
              assert_equal "ask_information", first.state["active_task"]
              assert_equal suspended, first.state["suspended_task"]

              @read_result = Contracts::ReadResult.new(status: "empty", warnings: ["no_matching_collected_notices"])
              second = turn("Ledinci", action: model_action, topic: model_action == "choose_area" ? "neighborhood" : "unknown", operation: "clarify", clarification: true)
              assert_equal "answered", second.resolution
              assert_equal "Ledinci", second.state.dig("entities", "area_query")
              assert_equal suspended, second.state["suspended_task"]
              assert_nil second.state["pending_slot"]
              assert_equal 0, second.state["clarification_count"]
              assert_equal(%w(ask_information ask_information), @reads.map { |read| read.fetch(:action) })
              refute second.handoff_completed
            end
          end

          def test_offered_public_report_choice_is_a_continuation_not_a_new_report
            prime_occupied_report
            saved = @state.fetch("suspended_task")
            @reads.clear
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
            result = turn("Javne prijave problema", action: "report_problem", topic: "report", operation: "clarify", clarification: true)
            assert_equal "clarification", result.resolution
            assert_equal "area_query", result.state["pending_slot"]
            assert_equal saved, result.state["suspended_task"]
            assert_equal "ask_information", @reads.last.fetch(:action)
            assert_equal "Javne prijave problema", @reads.last.dig(:entities, "query")
            refute result.handoff_completed
          end

          def test_public_report_mode_survives_missing_area_and_generic_area_followup
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
            first = turn("Javne prijave problema", action: "ask_information", operation: "start")
            assert_equal "area_query", first.state["pending_slot"]
            @read_result = Contracts::ReadResult.new(status: "empty", warnings: ["no_matching_public_reports"])
            second = turn("Ledinci", action: "help", topic: "unknown", operation: "clarify", clarification: true)
            # The fixture read carries no facts, so the turn ends with the "no verified
            # data" refusal. That is "unsupported", not "answered" (Task 9b).
            assert_equal "unsupported", second.resolution
            assert_equal "Javne prijave problema", @reads.last.dig(:entities, "query")
            assert_equal "Ledinci", @reads.last.dig(:entities, "area_query")
            refute @reads.last.fetch(:context).allows?("neighborhood_reads")
          end

          def test_explicit_public_query_stays_within_read_port_entity_limit
            result = turn("Javne prijave problema #{"za moj komšiluk " * 20}", action: "ask_information", operation: "start")
            assert_equal "unsupported", result.resolution
            assert_equal 160, @reads.last.dig(:entities, "query").length
            assert @reads.last.dig(:entities, "query").start_with?("Javne prijave problema")
          end

          def test_account_area_selection_is_not_rewritten_into_public_notice_lookup
            prime_occupied_report
            @read_result = Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"])
            turn("Servisne informacije")
            @reads.clear
            result = turn("Ledinci", action: "choose_area", topic: "account", operation: "continue")
            assert_equal "clarification", result.resolution
            assert_nil result.state.dig("entities", "area_query")
            assert_empty @reads
          end

          def test_closed_choice_matching_does_not_consume_member_posts_negation_other_tasks_or_guarded_inputs
            ["Ne želim servisne informacije", "Servisne informacije i objave članova", "Prijavi problem", "Objave članova"].each do |text|
              refute Procedures::Komsiluk.public_choice?(text)
              assert_nil Procedures::Komsiluk.area_answer(text)
            end
            ["Ledinci", "Лединци", "U Ledincima."].each { |text| assert Procedures::Komsiluk.area_answer(text) }
            prime_occupied_report
            result = turn("odustani", action: "cancel", topic: "unknown", operation: "cancel")
            assert_equal "cancelled", result.resolution
            assert_nil result.state["suspended_task"]

            prime_occupied_report
            @read_result = Contracts::ReadResult.new(status: "not_authorized")
            member = turn("Objave članova", action: "neighborhood_information", operation: "continue")
            assert_equal "neighborhood_information", @reads.last.fetch(:action)
            assert_equal "handoff", member.resolution
            refute @reads.last.fetch(:context).allows?("neighborhood_reads")
          end

          def test_public_action_uses_neighborhood_guidance_and_mixed_or_negated_board_request_is_not_guessed
            [["Ne objave nego javne prijave", "neighborhood_information"],
             ["Objave i servisne informacije", "neighborhood_information"]].each do |text, action|
              @state = StateStore.new.empty_state(@context)
              result = turn(text, action:, operation: "start")
              assert_equal "clarification", result.resolution
              refute result.handoff_offered
              assert_empty @reads
            end
          end

          def test_guidance_locales_and_prompt_preserve_bounded_private_public_distinction
            Contracts::LOCALES.each do |locale|
              @state = StateStore.new.empty_state(@context)
              result = turn("Objave i servisne informacije", operation: "start", locale:)
              assert_equal I18n.t("decidim.bih.dialogue.neighborhood_activity_choice", locale:), result.reply.text
              %w(neighborhood_service_choice neighborhood_public_reports neighborhood_no_notices).each do |key|
                assert I18n.exists?("decidim.bih.dialogue.#{key}", locale)
              end
            end
            instruction = YAML.load_file(File.expand_path("../../../../../../config/concierge/milica_understanding_v1.yml", __dir__)).fetch("system_instruction")
            assert_operator instruction.length, :<=, 8_000
            assert_includes instruction, "Šta se dešava u mom komšilu?"
            assert_includes instruction, '"U Ledincima" continues the public question, without requesting private posts'
          end

          private

          def prime_occupied_report
            @state = StateStore.new.empty_state(@context)
            @read_result = Contracts::ReadResult.new(status: "empty")
            turn("Parking", action: "ask_information", topic: "parking", operation: "start")
            turn("Rupa ispred kuće", action: "report_problem", topic: "roads", operation: "switch",
                                     entities: { description: "Rupa ispred kuće", address: "Ulica Primjer 14" })
            # A host-side report preview remains unsubmitted; represent that
            # state without invoking a report writer or storing a real token.
            @state = @state.merge("report_handoff_offered" => false)
            turn("Objave i servisne informacije", operation: "switch")
            assert_equal "report_problem", @state.dig("suspended_task", "active_task")
            assert_equal "Ulica Primjer 14", @state.dig("suspended_task", "entities", "address")
          end

          # Explicit keywords keep each fixture's Understanding fields visible.
          def turn(text, action: "neighborhood_information", topic: "neighborhood", operation: "continue", entities: {}, locale: "sr", clarification: false) # rubocop:disable Metrics/ParameterLists
            understanding = Contracts::Understanding.parse(action:, topic:, operation:, entities:, locale:, needs_clarification: clarification, secondary: nil)
            result = @runner.call(understanding:, state: @state, context: @context, message: Message.new(text:, dialogue_location: nil))
            @state = result.state
            result
          end
        end
      end
    end
  end
end

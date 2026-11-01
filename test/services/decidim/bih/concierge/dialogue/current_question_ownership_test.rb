# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Task 4, coordinator level: which turn owns the citizen's current
        # question, and what a control word is allowed to do to the task around
        # it. Every case names the cause it closes from the 14.09 failure trace
        # (docs/operations/milica-current-question-trace-2026-09-14.md).
        class CurrentQuestionOwnershipTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 10, 30)

          class FakeRedis
            attr_reader :versions

            def initialize
              @values = {}
              @versions = []
            end

            def get(key) = @values[key]

            def del(key)
              @values.delete(key)
              1
            end

            def eval(script, keys:, argv:)
              raise "Unexpected script" unless script == StateStore::WRITE_SCRIPT

              @versions << argv.first
              stored = @values[keys.first]
              version = stored ? JSON.parse(stored).fetch("version") : 0
              return 0 unless version == argv.first

              @values[keys.first] = argv[1]
              1
            end
          end

          class InlineRuntime
            def call
              AdmissionControl::Result.new(status: :admitted, value: yield(TurnBudget.new(timeout: 10.0)))
            end
          end

          Message = Data.define(:text, :conversation_context, :dialogue_location)

          def setup
            @previous = { backend: I18n.backend, load_path: I18n.load_path, available: I18n.available_locales, locale: I18n.locale }
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path = [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend = I18n::Backend::Simple.new
            I18n.locale = :sr # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.backend.send(:init_translations)
            @redis = FakeRedis.new
            @store = StateStore.new(redis: @redis)
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "e" * 64, actor_id: 7, now: NOW,
                                                     capabilities: %w(public_reads report_guidance registration_handoff))
            @understood = []
            @reads = []
            rewards = (1..5).map { |index| "MI! nagrada #{index}: opis nagrade broj #{index}. Cijena u bodovima: #{index * 10}." }
            @legacy_text = "#{rewards.join("\n\n")}\n\nIzvor: Bodovnik"
          end

          def teardown
            I18n.backend = @previous.fetch(:backend)
            I18n.load_path = @previous.fetch(:load_path)
            I18n.available_locales = @previous.fetch(:available)
            enforcing = I18n.enforce_available_locales
            I18n.enforce_available_locales = false
            I18n.locale = @previous.fetch(:locale) # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.enforce_available_locales = enforcing
          end

          # S8 / RC-5 — CANCEL_ACTION_PATTERN is unanchored, so the "ne prijava"
          # fragment inside a POSITIVE request cancelled the request.
          def test_a_negated_action_inside_a_positive_request_is_not_a_cancellation
            refute Coordinator.cancelled?("Treba mi službena stranica toplane, ne prijava problema.")
            refute Coordinator.cancelled?("Hoću kontakt Vodovoda, ne prijavu kvara")
            refute Coordinator.cancelled?("I need the official heating page, not a problem report")
          end

          def test_an_actual_cancellation_still_cancels
            ["odustani", "Nemoj objaviti ovo", "Ne želim da prijavim", "molim te ne prijavljuj ovo",
             "do not publish", "novi razgovor"].each do |text|
              assert Coordinator.cancelled?(text), text
            end
          end

          # Task 10, item 3. The same rule on the LEGACY brain. Task 4 fixed the
          # dialogue path through TextPredicates.cancel_action? but could not
          # edit responder.rb, so the Viber/legacy-web brain kept the unanchored
          # match and still threw away the positive request.
          def test_the_legacy_brain_applies_the_same_cancellation_rule
            responder = Responder.allocate

            ["Treba mi službena stranica toplane, ne prijava problema.",
             "Hoću kontakt Vodovoda, ne prijavu kvara"].each do |text|
              refute responder.send(:cancellation_signal?, text), text
            end

            ["odustani", "Nemoj objaviti ovo", "Ne želim da prijavim", "molim te ne prijavljuj ovo",
             "stop", "stop molim"].each do |text|
              assert responder.send(:cancellation_signal?, text), text
            end
          end

          # S7 / RC-5 — an ordinary closing that acknowledges before it thanks
          # was not a courtesy, reached the model, and came back as a cancel.
          def test_an_ordinary_closing_is_a_courtesy_and_never_a_cancellation
            ["Dobro, hvala.", "ok hvala", "u redu hvala ti", "jasno, hvala puno", "hvala, to je sve"].each do |text|
              assert_equal "thanks", Courtesy.kind(text), text
              refute Coordinator.cancelled?(text), text
            end
          end

          # RC-6 — the evidence follow-ups were folded EQUALITY against six
          # phrases; every other phrasing of the same question went to the model.
          def test_the_evidence_follow_ups_recognise_the_same_question_phrased_differently
            { "odakle ti to" => "source", "a odakle ti taj podatak" => "source", "koji je izvor za to" => "source",
              "za koji datum vazi" => "date", "od kada to vazi" => "date",
              "nije tako kod mene" => "disagreement", "kod nas to nije tako" => "disagreement" }.each do |text, kind|
              assert_equal kind, Coordinator.prior_evidence_kind(text), text
            end
            assert_nil Coordinator.prior_evidence_kind("odakle ti to i kada se odvozi smeće")
          end

          # RC-7 — the legacy read adapter is the only answering path that never
          # reached accept_candidate, so the next turn was classified against
          # the task the citizen had already left.
          # The prompt is deliberately one NO deterministic route claims, so the
          # turn is still the MODEL-classified secondary read this case was
          # written for. "Šta su bodovi zajedništva?" used to serve here and no
          # longer can: the points-explanation route now answers it before the
          # model is asked (points_explainer_route.rb), which is a different
          # path through the same adapter.
          def test_a_legacy_secondary_answer_persists_its_own_task
            seed(active_task: "ask_information", topic: "rewards", entities: { "query" => "nagrade" })
            result = coordinator(secondary: true).call(message: chat_message("A šta je sa bodovima za volontiranje?"), context: @context)

            assert_equal "answered", result.resolution
            refute_empty @understood, "this case is about the model-classified secondary read"
            saved = @store.read(context: @context)
            assert_equal "goodwill", saved.fetch("topic"), "the answered topic, not the superseded one"
            assert_equal "ask_information", saved.fetch("active_task")
            assert_equal({ "query" => "sta su bodovi zajednistva" }, saved.fetch("entities"))
            assert_equal [1], @redis.versions.drop(1), "exactly one CAS write for the answered turn"
          end

          def test_a_brevity_request_about_a_legacy_answer_shortens_it_without_a_second_model_call
            seed(active_task: "ask_information", topic: "goodwill", entities: { "query" => "bodovi" })
            result = coordinator(secondary: true).call(message: chat_message("Kraće."), context: @context)

            assert_equal "answered", result.resolution
            assert_operator result.reply.text.length, :<, @legacy_text.length
            assert_empty @understood, "a presentation request never reaches the model"
          end

          # S12 — resume_with_nothing_suspended? required that NO task was open
          # either, so repeating "nastavi" after a resume went to the model and
          # came back as the identical question, charged to the budget.
          def test_repeating_nastavi_with_nothing_suspended_never_reaches_the_model
            seed(active_task: "registration", topic: "account", pending_slot: "query", clarification_count: 1)
            result = coordinator.call(message: chat_message("nastavi"), context: @context)

            assert_equal I18n.t("decidim.bih.dialogue.resume_nothing", locale: :sr), result.reply.text
            assert_equal "answered", result.resolution
            assert_empty @understood
            assert_empty @reads
            assert_equal [0], @redis.versions, "only the fixture write may touch the state"
            assert_equal 1, @store.read(context: @context).fetch("clarification_count")
          end

          # "kraće" had no representation anywhere: it reached the model, which
          # answered it as a clarification or executed it as a cancellation.
          def test_a_brevity_request_continues_the_saved_task_without_the_model
            seed(active_task: "ask_information", topic: "waste", entities: { "query" => "odvoz smeća", "area_query" => "Dvorovi" })
            result = coordinator.call(message: chat_message("Kraće molim."), context: @context)

            refute_equal "cancelled", result.resolution
            assert_empty @understood, "a presentation request never reaches the model"
            assert_equal 1, @reads.length, "the same question, re-rendered, not a new task"
            assert_equal "odvoz smeća", @reads.last.fetch(:entities)["query"]
            assert_equal "waste", @store.read(context: @context).fetch("topic")
          end

          # The reserved emergency-continuity key and the new presentation level
          # are both scoped to one organization, actor and conversation.
          def test_the_saved_presentation_level_never_crosses_an_actor_or_tenant_boundary
            seed(active_task: "ask_information", topic: "waste", entities: { "query" => "odvoz smeća", "area_query" => "Dvorovi" })
            coordinator.call(message: chat_message("Kraće molim."), context: @context)
            assert_equal "short", @store.read(context: @context).fetch(StateStore::PRESENTATION_LEVEL_KEY)

            other_actor = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "e" * 64, actor_id: 8, now: NOW,
                                                        capabilities: %w(public_reads))
            other_tenant = Contracts::TrustedContext.new(organization_id: 2, conversation_key: "e" * 64, actor_id: 7, now: NOW,
                                                         capabilities: %w(public_reads))
            [other_actor, other_tenant].each do |context|
              assert_nil @store.read(context:).fetch(StateStore::PRESENTATION_LEVEL_KEY)
              assert_nil @store.read(context:).fetch("active_task")
            end
          end

          def test_clearing_the_conversation_drops_the_presentation_level
            seed(active_task: "ask_information", topic: "waste", entities: { "query" => "odvoz smeća", "area_query" => "Dvorovi" })
            coordinator.call(message: chat_message("Kraće molim."), context: @context)
            @store.clear(context: @context)

            assert_nil @store.read(context: @context).fetch(StateStore::PRESENTATION_LEVEL_KEY)
          end

          private

          # Minitest::Assertions already owns #message.
          def chat_message(text)
            Message.new(text:, conversation_context: [], dialogue_location: nil)
          end

          def seed(**attributes)
            state = @store.empty_state(@context).merge(attributes.transform_keys(&:to_s))
            state["entity_provenance"] = state.fetch("entities").keys.to_h { |key| [key, "citizen"] }
            raise "Fixture state rejected" unless @store.write(context: @context, state:, expected_version: 0) == :saved
          end

          def coordinator(secondary: false)
            understanding = lambda do |**arguments|
              @understood << arguments
              Contracts::Understanding.parse(action: "ask_information", topic: "goodwill", entities: { "query" => "sta su bodovi zajednistva" },
                                             operation: "switch", needs_clarification: false, secondary: nil, locale: "sr")
            end
            procedures = ProcedureRunner.new(
              read_port: lambda { |**arguments|
                @reads << arguments
                Contracts::ReadResult.new(status: "empty")
              },
              registration_port: ->(**) { Contracts::HandoffResult.new(account_state: "registered", next_step: "verification", destination: "/mi/moj-nalog") },
              destinations: { report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: "/pages/pomoc" }
            )
            Coordinator.new(understanding:, procedures:, state_store: @store, runtime: InlineRuntime.new,
                            legacy_secondary: secondary ? legacy_adapter : nil)
          end

          def legacy_adapter
            responder = Object.new
            text = @legacy_text
            responder.define_singleton_method(:respond) do |_message|
              Responder::Reply.new(text:, report: nil, answer_intent: "goodwill", tone: "core")
            end
            Coordinator::LegacyReadAdapter.new(responder:)
          end
        end
      end
    end
  end
end

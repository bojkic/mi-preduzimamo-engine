# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class CoordinatorCancellationTest < Minitest::Test
          NOW = Time.utc(2026, 9, 9, 12)

          class FakeRedis
            attr_reader :values, :versions
            attr_accessor :reject_version

            def initialize
              @values = {}
              @versions = []
            end

            def get(key) = values[key]

            def eval(script, keys:, argv:)
              raise "Unexpected script" unless script == StateStore::WRITE_SCRIPT

              versions << argv.first
              return 0 if reject_version == argv.first

              stored = values[keys.first]
              version = stored ? JSON.parse(stored).fetch("version") : 0
              return 0 unless version == argv.first

              values[keys.first] = argv[1]
              1
            end
          end

          class InlineRuntime
            def call
              AdmissionControl::Result.new(status: :admitted, value: yield(TurnBudget.new(timeout: 1)))
            end
          end

          def setup
            @previous_backend = I18n.backend
            @previous_load_path = I18n.load_path
            @previous_locales = I18n.available_locales
            @previous_locale = I18n.locale
            I18n.available_locales = Contracts::LOCALES
            # Control replies follow the UI locale; the web request runs under sr.
            I18n.locale = :sr # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.load_path = [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend = I18n::Backend::Simple.new
            I18n.backend.send(:init_translations)
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, now: NOW,
                                                     capabilities: %w(public_reads report_guidance registration_handoff))
            @reads = []
            @understood = []
            @provider_failure = false
            seed_report
          end

          def teardown
            I18n.backend = @previous_backend
            I18n.load_path = @previous_load_path
            I18n.available_locales = @previous_locales
            I18n.locale = @previous_locale # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
          end

          def test_cancel_trip_preserves_the_account_deletion_question
            result = coordinator.call(message: "Одустајем од пута. Како обрисати налог?", context: @context)
            assert_equal 1, @understood.length
            assert_equal "Како обрисати налог?", @understood.first.fetch(:message).text
            assert_cleared(@understood.first.fetch(:stored_before_provider))
            refute_equal "cancelled", result.resolution
          end

          def test_separated_new_question_starts_only_after_report_cancellation_is_saved
            message = Data.define(:text, :conversation_context, :dialogue_location).new(
              text: "Odustajem od prijave. Kako mogu vidjeti objave iz svog komšiluka?",
              conversation_context: [{ "user" => "Stari opis", "assistant" => "Stari odgovor", "issued_at" => NOW.to_f }],
              dialogue_location: { latitude: 44.75, longitude: 19.2 }
            )
            result = coordinator.call(message:, context: @context)

            assert_equal "handoff", result.resolution
            assert_equal 1, @understood.size
            call = @understood.fetch(0)
            assert_equal "Kako mogu vidjeti objave iz svog komšiluka?", call.fetch(:message).text
            assert_empty call.fetch(:history)
            assert_cleared(call.fetch(:state))
            assert_cleared(call.fetch(:stored_before_provider))
            assert_equal [0, 1, 2], @redis.versions
            assert_equal "neighborhood_information", @store.read(context: @context).fetch("active_task")
            assert_empty @reads.fetch(0).fetch(:entities)
            assert_nil @reads.fetch(0).fetch(:location)
            refute @reads.fetch(0).fetch(:context).allows?("neighborhood_reads")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.cancelled_then_next", locale: :sr)
            assert_nil result.reply.report
            refute result.handoff_completed
          end

          def test_standalone_controls_and_protected_combinations_do_not_call_understanding
            ["odustani", "clear", "Ne objavljuj ovo; promijeni adresu", "Odustani. Kako da unesem kod 123456?"].each do |message|
              seed_report
              result = coordinator.call(message:, context: @context)

              assert_equal "cancelled", result.resolution
              assert_cleared(@store.read(context: @context))
              assert_empty @understood
              assert_empty @reads
            end
            message = Data.define(:text) { def safety_signal? = true }.new("Odustani. Kako da potražim pomoć?")
            seed_report
            result = coordinator.call(message:, context: @context)
            assert_equal "safety_guidance", result.resolution
            assert_equal "safety", result.reply.answer_intent
            assert_cleared(@store.read(context: @context))
            assert_empty @understood
          end

          def test_real_text_danger_cancellation_clears_prior_report_and_keeps_only_bounded_safety_context
            ["Odustani. Gori mi kuća, šta da radim?", "Одустани. Гори ми кућа, шта да радим?"].each do |text|
              seed_report
              before = @store.read(context: @context)
              result = coordinator.call(message: text, context: @context)
              saved = @store.read(context: @context)

              assert_equal "safety_guidance", result.resolution
              assert_equal "safety", result.reply.answer_intent
              assert_cleared(saved)
              assert_nil saved[StateStore::QUESTION_QUEUE_KEY]
              assert_equal "fire", saved.dig(StateStore::SAFETY_CONTEXT_KEY, "kind")
              assert_equal "unknown", saved.dig(StateStore::SAFETY_CONTEXT_KEY, "topic")
              assert_equal before.fetch("created_at"), saved.fetch("created_at")
              assert_equal before.fetch("locale"), saved.fetch("locale")
              assert_equal before.fetch("version") + 1, saved.fetch("version")
              assert_includes result.reply.text, "123"
              assert_nil result.reply.report
              assert_empty result.fact_ids
              refute result.handoff_completed
              assert_empty @understood
              assert_empty @reads
            end
          end

          def test_failed_real_danger_cancellation_cas_delivers_card_without_claiming_cancellation_saved
            @redis.reject_version = 1
            result = coordinator.call(message: "Odustani. Gori mi kuća, šta da radim?", context: @context)

            assert_equal "safety_guidance", result.resolution
            assert_equal "safety", result.reply.answer_intent
            assert_nil result.state
            assert_equal "report_problem", @store.read(context: @context).fetch("active_task")
            assert_includes result.reply.text, "123"
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.cancelled", locale: :sr)
            assert_nil result.reply.report
            assert_empty result.fact_ids
            refute result.handoff_completed
            assert_empty @understood
            assert_empty @reads
          end

          def test_failed_cancellation_cas_cannot_start_the_new_question
            @redis.reject_version = 1
            result = coordinator.call(message: "Cancel the report. How can I read my neighborhood board?", context: @context)

            assert_equal "unsupported", result.resolution
            assert_empty @understood
            assert_empty @reads
            assert_equal "report_problem", @store.read(context: @context).fetch("active_task")
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.cancelled", locale: :sr)
          end

          def test_provider_or_second_cas_failure_never_restores_the_cancelled_report
            [:provider, :second_cas].each do |failure|
              seed_report
              @understood.clear
              @provider_failure = failure == :provider
              @redis.reject_version = 2 if failure == :second_cas
              result = coordinator.call(message: "Одустајем од пријаве. Како могу видјети објаве комшилука?", context: @context)

              assert_equal "unsupported", result.resolution
              assert_equal 1, @understood.size
              assert_cleared(@store.read(context: @context))
              assert_nil result.reply.report
              refute result.handoff_completed
            end
          end

          # Task 10, item 2. The coordinator-only boundary (Viber's
          # dialogue_turn, and the web whenever the report conversation is not
          # wrapping the turn) answered EVERY danger with the all-services
          # card, while the host path this deployment actually takes already
          # names the relevant service. Typed danger now gets the same card.
          def test_typed_danger_gets_the_relevant_service_card_at_the_control_boundary
            { "Gori kontejner ispred zgrade!" => "emergency_fire",
              "Curi plin u stanu" => "emergency_gas",
              "Komšija ne diše" => "emergency_medical" }.each do |text, key|
              reply = Coordinator.control_reply(message: text)

              assert_equal "safety", reply.answer_intent, text
              assert_equal "core", reply.tone, text
              assert_includes reply.text, I18n.t("decidim.bih.dialogue.#{key}", locale: :sr, raise: true), text
              assert_includes reply.text, I18n.t("decidim.bih.dialogue.emergency_disclaimer", locale: :sr, raise: true), text
              refute_equal I18n.t("decidim.bih.dialogue.safety", locale: :sr), reply.text, text
            end
          end

          # A Cyrillic emergency is answered in Cyrillic, and an UNTYPED danger
          # (a threat, an assault) keeps the all-services card: there the
          # police and the SOS line ARE the relevant services.
          def test_untyped_danger_keeps_the_all_services_card_and_the_citizens_script
            assert_equal I18n.t("decidim.bih.dialogue.safety", locale: :sr),
                         Coordinator.control_reply(message: "Neko mi prijeti, bojim se").text
            assert_equal I18n.t("decidim.bih.dialogue.safety", locale: :"sr-Cyrl"),
                         Coordinator.control_reply(message: "Зови полицију, напали су ме").text
            assert_includes Coordinator.control_reply(message: "Гори контејнер испред зграде!").text,
                            I18n.t("decidim.bih.dialogue.emergency_fire", locale: :"sr-Cyrl", raise: true)
          end

          def test_courtesy_answers_before_admission_without_cancelling_or_touching_state
            reply = Coordinator.control_reply(message: "hvala ti puno")
            assert_equal I18n.t("decidim.bih.dialogue.thanks", locale: :sr), reply.text
            assert_equal "help", reply.answer_intent
            assert_equal "neighborly", reply.tone
            refute Coordinator.cancelled?("hvala")
            refute Coordinator.cancelled?("pozdrav i hvala")
            assert_equal I18n.t("decidim.bih.dialogue.greeting", locale: :"sr-Cyrl"), Coordinator.control_reply(message: "Здраво").text
            assert_equal I18n.t("decidim.bih.dialogue.capabilities", locale: :sr), Coordinator.control_reply(message: "Šta sve znaš?").text
            assert_equal I18n.t("decidim.bih.dialogue.clarify", locale: :sr), Coordinator.control_reply(message: "pomoc").text

            %w(hvala Zdravo doviđenja).each do |text|
              result = coordinator.call(message: text, context: @context)

              assert_equal "answered", result.resolution
              assert_equal "help", result.reply.answer_intent
              assert_nil result.reply.report
              assert_equal "report_problem", @store.read(context: @context).fetch("active_task"), text
              assert_equal "registration", @store.read(context: @context).dig("suspended_task", "active_task"), text
              assert_equal [0], @redis.versions, "only the fixture write may touch the state (#{text})"
              assert_empty @understood
              assert_empty @reads
            end
          end

          def test_resume_with_nothing_suspended_answers_deterministically_and_keeps_state
            @redis = FakeRedis.new
            @store = StateStore.new(redis: @redis)
            %w(nastavi Nastavi настави continue).each do |text|
              result = coordinator.call(message: text, context: @context)

              locale = text.match?(/\p{Cyrillic}/) ? :"sr-Cyrl" : :sr
              assert_equal I18n.t("decidim.bih.dialogue.resume_nothing", locale:), result.reply.text, text
              assert_equal "answered", result.resolution
              assert_equal "help", result.reply.answer_intent
              assert_empty @understood, "no understanding call for #{text}"
              assert_empty @reads
              assert_empty @redis.versions, "no state write for #{text}"
              assert_nil @store.read(context: @context).fetch("active_task")
            end
          end

          private

          def assert_cleared(state)
            assert_nil state.fetch("active_task")
            assert_nil state.fetch("pending_slot")
            assert_nil state.fetch("suspended_task")
            assert_nil state.fetch("draft")
            assert_empty state.fetch("entities")
            assert_empty state.fetch("entity_provenance")
            assert_nil state.fetch("prior_evidence")
          end

          def seed_report
            @redis = FakeRedis.new
            @store = StateStore.new(redis: @redis)
            empty = @store.empty_state(@context)
            state = empty.merge(
              "active_task" => "report_problem", "topic" => "roads", "pending_slot" => "area_query",
              "entities" => { "description" => "Oštećen trotoar" }, "entity_provenance" => { "description" => "citizen" },
              "draft" => { "reference" => "d" * 16, "revision" => 1, "expires_at" => (NOW + 60).to_f },
              "suspended_task" => empty.slice(*StateStore::TASK_KEYS).merge("active_task" => "registration", "topic" => "account")
            )
            raise "Fixture state rejected" unless @store.write(context: @context, state:, expected_version: 0) == :saved
          end

          def coordinator
            understanding = lambda do |**arguments|
              @understood << arguments.merge(stored_before_provider: @store.read(context: @context))
              raise "Synthetic provider failure" if @provider_failure

              Contracts::Understanding.parse(action: "neighborhood_information", topic: "neighborhood", entities: {},
                                             operation: "start", needs_clarification: false, secondary: nil, locale: "sr")
            end
            procedures = ProcedureRunner.new(
              read_port: lambda { |**arguments|
                @reads << arguments
                Contracts::ReadResult.new(status: "not_authorized")
              },
              registration_port: ->(**) { raise "Unexpected account action" },
              destinations: { report: "/report", neighborhood: "/board", account: "/account", support: "/help" }
            )
            Coordinator.new(understanding:, procedures:, state_store: @store, runtime: InlineRuntime.new)
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/exclude"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/understand"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Actual Coordinator/Runner, persisted in-memory CAS and a typed public
        # read seam. No Rails, Redis, database, network or provider calls.
        class ServiceFollowUpIntegrationTest < Minitest::Test
          NOW = Time.utc(2026, 9, 10, 9)
          SOURCE_ID = "city_services:parking"
          OLD_URL = "https://obsolete.example.test/payment"
          CURRENT_URL = "https://current.example.test/official-service"
          SOURCE_LABEL = "Reviewed parking service"

          class MemoryRedis
            attr_reader :values, :writes

            def initialize
              @values = {}
              @writes = 0
            end

            def get(key) = values[key]

            def eval(script, keys:, argv:)
              raise "Unexpected state operation" unless script == StateStore::WRITE_SCRIPT

              version = values[keys.first] ? JSON.parse(values[keys.first]).fetch("version") : 0
              return 0 unless version == argv.first

              values[keys.first] = argv[1]
              @writes += 1
              1
            end
          end

          class InlineRuntime
            attr_accessor :clock, :expire_before_work

            def initialize = @clock = 0.0

            def call
              budget = TurnBudget.new(timeout: 1.0, clock: -> { clock })
              @clock = 2.0 if expire_before_work
              AdmissionControl::Result.new(status: :admitted, value: yield(budget))
            end
          end

          def setup
            @prior_backend = I18n.backend
            @prior_locales = I18n.available_locales
            @prior_locale = I18n.locale
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.locale = :sr
            I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "a" * 64, capabilities: ["public_reads"], now: NOW)
            @runtime = InlineRuntime.new
            @service_reads = []
            @understood = []
            @other_reads = []
            port = Object.new
            owner = self
            port.define_singleton_method(:service_follow_up) { |**arguments| owner.service_read(arguments) }
            port.define_singleton_method(:call) do |**arguments|
              owner.instance_variable_get(:@other_reads) << arguments
              Contracts::ReadResult.new(status: "empty")
            end
            @runner = ProcedureRunner.new(read_port: port, registration_port: ->(**) { flunk "Unexpected account handoff" },
                                          destinations: { report: "/reports/new", account: "/account", support: "/help", neighborhood: "/board" })
            seed
          end

          def teardown
            I18n.backend = @prior_backend
            I18n.available_locales = @prior_locales
            I18n.locale = @prior_locale
          end

          def service_read(arguments)
            @service_reads << arguments
            @runtime.clock = 2.0 if @expire_on_read
            @on_read&.call
            return @result_override if @result_override

            focus = arguments.fetch(:focus)
            key = focus == "contact" ? "service_contact_unavailable" : "service_official_page"
            text = I18n.t("decidim.bih.dialogue.#{key}", locale: arguments.fetch(:locale), title: SOURCE_LABEL, raise: true)
            warnings = ["snapshot_not_live_status"]
            warnings << "reviewed_service_contact_unavailable" if focus == "contact"
            Contracts::ReadResult.new(status: "ok", facts: [service_fact.merge("text" => text, "source_url" => CURRENT_URL, "observed_at" => "2026-09-10")],
                                     coverage: { "scope" => "reviewed_static_directory", "focus" => focus, "contact_available" => false },
                                     validity: { "reviewed_on" => "2026-09-10", "live_status" => false }, warnings:)
          end

          def test_contact_then_website_use_fresh_source_without_model_and_preserve_current_and_suspended_tasks
            [["A koji je broj telefona službe?", "A gdje je njihova stranica?", "sr"],
             ["А који је број телефона службе?", "А гдје је њихова страница?", "sr-Cyrl"],
             ["What is their phone number?", "Where is their website?", "en"]].each do |contact, website, locale|
              seed
              before = @store.read(context: @context)
              [contact, website].zip(%w(contact website)).each do |message, focus|
                response = coordinator.call(message:, context: @context)
                copy = focus == "contact" ? "service_contact_unavailable" : "service_official_page"
                expected = I18n.t("decidim.bih.dialogue.#{copy}", locale:, title: SOURCE_LABEL, raise: true)

                assert_equal "answered", response.resolution, message
                assert_includes response.reply.text, expected
                assert_includes response.reply.text, CURRENT_URL
                refute_includes response.reply.text, OLD_URL
                refute_match(/083[ ]5501|Old payment/, response.reply.text)
                assert_equal ["service:parking"], response.fact_ids
                assert_equal %i(context focus locale source_id), @service_reads.last.keys.sort
                assert_equal [SOURCE_ID, focus, locale], @service_reads.last.values_at(:source_id, :focus, :locale)
                assert_equal @context.to_h.except(:deadline), @service_reads.last.fetch(:context).to_h.except(:deadline)
                assert_equal before.values_at("active_task", "topic", "entities", "entity_provenance", "suspended_task"),
                             response.state.values_at("active_task", "topic", "entities", "entity_provenance", "suspended_task")
                assert_equal "2026-09-10", response.state.dig("prior_evidence", "facts", 0, "observed_at")
                assert_nil response.reply.report
                refute response.handoff_completed
              end
              assert_equal 3, @redis.writes
              assert_empty @understood
              assert_empty @other_reads
            end
          end

          def test_absent_expired_ambiguous_or_private_evidence_never_intercepts
            private_read = Contracts::ReadResult.new(status: "ok", facts: [service_fact],
                                                     coverage: { "visibility" => "member_board", "area_slugs" => ["komsiluk-1"] })
            private_evidence = PriorEvidence.capture(result: private_read, facts: private_read.facts, action: "neighborhood_information", topic: "neighborhood",
                                                      now: NOW, expires_at: NOW.to_f + 600)
            [nil, evidence.merge("expires_at" => NOW.to_f - 1), private_evidence,
             evidence(facts: [service_fact, service_fact.merge("id" => "service:other", "source_id" => "city_services:other")])].each do |prior|
              seed(prior:)
              coordinator.call(message: "A koji je broj telefona službe?", context: @context)
              assert_empty @service_reads
              assert_equal 1, @understood.length
            end
          end

          def test_wrong_task_draft_or_missing_read_capability_does_not_reuse_source
            draft = { "reference" => "opaque_fixture_123", "revision" => 1, "expires_at" => NOW.to_f + 60 }
            [{ task: "report_problem", topic: "roads" }, { topic: "water" }, { draft: }, { capabilities: [] }].each do |options|
              seed(**options)
              coordinator.call(message: "A gdje je njihova stranica?", context: @context)
              assert_empty @service_reads
              assert_equal 1, @understood.length
            end
          end

          def test_named_new_services_sms_numbers_private_contacts_and_mixed_requests_do_not_intercept
            ["Koji je telefon Vodovoda?", "Koji je SMS broj?", "Telefon direktora", "Ne treba mi njihov telefon",
             "A broj telefona službe i plati parking", "Where is their website and how much is a bus ticket?"].each do |message|
              seed
              coordinator.call(message:, context: @context)
              assert_empty @service_reads, message
              assert_equal 1, @understood.length, message
            end
          end

          def test_unavailable_fresh_read_cannot_replay_old_source_or_payment
            @result_override = Contracts::ReadResult.new(status: "unavailable", warnings: ["reviewed_service_not_found"])
            response = coordinator.call(message: "A telefon?", context: @context)
            assert_equal "source_unavailable", response.resolution
            assert_equal 1, @service_reads.length
            refute_includes response.reply.text, OLD_URL
            refute_includes response.reply.text, CURRENT_URL
            refute_match(/083[ ]5501|Old payment/, response.reply.text)
            assert_nil response.state.fetch("prior_evidence")
            assert_empty @understood
          end

          def test_deadline_before_or_during_read_does_not_accept_or_publish_source
            %i(before_read during_read).each do |failure|
              seed
              before = @store.read(context: @context)
              @runtime.expire_before_work = failure == :before_read
              @expire_on_read = failure == :during_read
              response = coordinator.call(message: "A telefon?", context: @context)
              assert_safe_rejection(response)
              assert_equal before, @store.read(context: @context)
              assert_equal 1, @redis.writes
              assert_equal(failure == :before_read ? 0 : 1, @service_reads.length)
            end
          end

          def test_real_competing_state_write_wins_cas_and_withholds_candidate_source
            @on_read = lambda do
              current = @store.read(context: @context)
              newer = current.merge("entities" => { "query" => "New concurrent parking question" }, "prior_evidence" => nil)
              assert_equal :saved, @store.write(context: @context, state: newer, expected_version: current.fetch("version"))
              @concurrent_state = @store.read(context: @context)
            end
            response = coordinator.call(message: "A gdje je njihova stranica?", context: @context)
            assert_safe_rejection(response)
            assert_equal @concurrent_state, @store.read(context: @context)
            assert_equal 2, @redis.writes
            assert_equal 1, @service_reads.length
          end

          def test_actual_understand_provider_error_returns_unavailable_without_state_write_or_clarification_cost
            calls = []
            client = Object.new
            client.define_singleton_method(:configured?) { true }
            client.define_singleton_method(:generate_content) do |**arguments|
              calls << arguments
              raise Decidim::Bih::Ai::Error, "HTTP 403 synthetic confidential provider detail"
            end
            understanding = Understand.new(client:, wall_clock: -> { NOW })
            actual = Coordinator.new(understanding:, procedures: @runner, state_store: @store, runtime: @runtime)
            before = @store.read(context: @context)
            response = actual.call(message: "Kako da platim parking?", context: @context)

            assert_equal 1, calls.length
            assert_safe_rejection(response, resolution: "provider_unavailable")
            assert_equal "fallback", response.reply.answer_intent
            fallback = I18n.t("decidim.bih.dialogue.context_unavailable", locale: "sr", raise: true)
            assert_includes response.reply.text, I18n.t("decidim.bih.dialogue.provider_unavailable", locale: "sr", default: fallback)
            refute_match(/403|confidential|provider detail/, response.reply.text)
            assert_equal before, @store.read(context: @context)
            assert_equal 1, @redis.writes
            assert_empty @service_reads
            assert_empty @other_reads
          end

          private

          def assert_safe_rejection(response, resolution: "unsupported")
            assert_equal resolution, response.resolution
            refute_includes response.reply.text, CURRENT_URL
            refute_includes response.reply.text, OLD_URL
            assert_empty response.fact_ids
            assert_empty @understood
            assert_nil response.reply.report
            refute response.handoff_completed
          end

          def service_fact
            { "id" => "service:parking", "kind" => "service_directory", "text" => "Old payment shortcode 083 5501",
              "source_id" => SOURCE_ID, "source_label" => SOURCE_LABEL, "source_url" => OLD_URL, "observed_at" => "2026-06-29" }
          end

          def evidence(facts: [service_fact])
            result = Contracts::ReadResult.new(status: "ok", facts:)
            PriorEvidence.capture(result:, facts:, action: "ask_information", topic: "parking", now: NOW, expires_at: NOW.to_f + 600)
          end

          def seed(prior: evidence, task: "ask_information", topic: "parking", draft: nil, capabilities: ["public_reads"])
            @context = @context.with(capabilities:)
            @redis = MemoryRedis.new
            @store = StateStore.new(redis: @redis)
            initial = @store.empty_state(@context)
            suspended = initial.slice(*StateStore::TASK_KEYS).merge("active_task" => "ask_information", "topic" => "transport",
                                                                   "entities" => { "query" => "Autobuska karta" }, "entity_provenance" => { "query" => "citizen" })
            state = initial.merge("active_task" => task, "topic" => topic, "draft" => draft, "prior_evidence" => prior, "suspended_task" => suspended,
                                  "entities" => { "query" => "Plaćanje crvene parking zone" }, "entity_provenance" => { "query" => "citizen" })
            raise "Synthetic seed rejected" unless @store.write(context: @context, state:, expected_version: 0) == :saved

            @service_reads.clear
            @other_reads.clear
            @understood.clear
            @runtime.clock = 0.0
            @runtime.expire_before_work = false
            @expire_on_read = false
            @on_read = nil
            @result_override = nil
          end

          def coordinator
            understanding = lambda do |**arguments|
              @understood << arguments
              Contracts::Understanding.clarify(locale: "sr")
            end
            Coordinator.new(understanding:, procedures: @runner, state_store: @store, runtime: @runtime)
          end
        end
      end
    end
  end
end

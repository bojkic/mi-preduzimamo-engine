# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/exclude"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Real coordinator/runner with in-memory state and a typed read port.
        # No Rails boot, database, Redis, source fetch or model calls.
        class ProcedureFeeFollowUpTest < Minitest::Test
          NOW = Time.utc(2026, 9, 9, 12)
          PROCEDURE_ID = "procedure:izvod_maticna_knjiga"
          OLD_URL = "https://old.example.test/obsolete-form"
          CURRENT_URL = "https://current.example.test/official-instructions"
          CURRENT_TEXT = "Current fixture fee guidance; postage must be checked with the service."

          class MemoryRedis
            attr_reader :values, :writes
            attr_accessor :reject_write

            def initialize
              @values = {}
              @writes = 0
            end

            def get(key) = values[key]

            def eval(script, keys:, argv:)
              raise "Unexpected state operation" unless script == StateStore::WRITE_SCRIPT
              return 0 if reject_write

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
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))
            @context = Contracts::TrustedContext.new(organization_id: 71, actor_id: 11, conversation_key: "a" * 64,
                                                     capabilities: ["public_reads"], now: NOW)
            @runtime = InlineRuntime.new
            @fee_reads = []
            @other_reads = []
            @understood = []
            @port = Object.new
            owner = self
            @port.define_singleton_method(:procedure_follow_up) { |**arguments| owner.fee_read(arguments) }
            @port.define_singleton_method(:call) { |**arguments| owner.other_read(arguments) }
            @runner = ProcedureRunner.new(read_port: @port, registration_port: ->(**) { flunk "Unexpected account handoff" },
                                          destinations: { report: "/reports/new", account: "/account", support: "/help", neighborhood: "/board" })
            seed
          end

          def teardown
            I18n.backend = @prior_backend
            I18n.available_locales = @prior_locales
          end

          def fee_read(arguments)
            @fee_reads << arguments
            @runtime.clock = 2.0 if @expire_on_read
            @fee_result
          end

          def other_read(arguments)
            @other_reads << arguments
            Contracts::ReadResult.new(status: "empty")
          end

          def test_retained_procedure_fee_followup_skips_model_and_uses_only_fresh_port_evidence
            ["A gdje provjeravam tu cijenu?", "А гдје провјеравам ту цијену?", "And where can I check the fee?"].each do |text|
              seed
              response = coordinator.call(message: text, context: @context)

              assert_equal "answered", response.resolution, text
              assert_includes response.reply.text, CURRENT_TEXT
              assert_includes response.reply.text, CURRENT_URL
              refute_includes response.reply.text, OLD_URL
              refute_includes response.reply.text, "Old fixture fee"
              assert_equal [PROCEDURE_ID], response.fact_ids
              assert_equal %i(context focus locale procedure_id), @fee_reads.last.keys.sort
              assert_equal [PROCEDURE_ID, "fee"], @fee_reads.last.values_at(:procedure_id, :focus)
              assert_equal @context.to_h.except(:deadline), @fee_reads.last.fetch(:context).to_h.except(:deadline)
              refute @fee_reads.last.fetch(:context).deadline.expired?
              assert_equal "ask_information", response.state.fetch("active_task")
              assert_equal "city_service", response.state.fetch("topic")
              assert_equal 2, @redis.writes
              assert_empty @understood
              assert_empty @other_reads
              assert_nil response.reply.report
              refute response.handoff_completed
            end
            assert_equal "en", @fee_reads.last.fetch(:locale)
          end

          def test_unexpired_stale_metadata_can_select_id_but_never_supply_the_answer
            seed(prior: evidence(status: "stale"))
            response = coordinator.call(message: "Koliko to košta?", context: @context)
            assert_equal "answered", response.resolution
            assert_equal 1, @fee_reads.length
            assert_includes response.reply.text, CURRENT_TEXT
            refute_includes response.reply.text, OLD_URL
            assert_equal "ok", response.state.dig("prior_evidence", "status")
            assert_empty @understood
          end

          def test_missing_expired_wrong_source_and_multiple_procedures_do_not_authorize_fee_followup
            [nil, evidence(expiry: NOW.to_f - 1), evidence(source: "other_registry"),
             evidence(facts: [procedure_fact, procedure_fact.merge("id" => "procedure:other", "source_id" => "procedure:other")])].each do |prior|
              seed(prior:)
              coordinator.call(message: "A gdje provjeravam tu cijenu?", context: @context)
              assert_empty @fee_reads
              assert_equal 1, @understood.length
            end
          end

          def test_wrong_active_task_draft_or_missing_public_read_capability_rejects_reuse
            draft = { "reference" => "opaque_fixture_123", "revision" => 1, "expires_at" => NOW.to_f + 60 }
            [{ task: "report_problem", topic: "roads" }, { topic: "transport" }, { draft: }, { capabilities: [] }].each do |options|
              seed(**options)
              coordinator.call(message: "Koliko to košta?", context: @context)
              assert_empty @fee_reads
              assert_equal 1, @understood.length
            end
          end

          def test_new_named_prices_and_mixed_or_negative_requests_do_not_reuse_the_procedure
            ["Koliko košta autobuska karta?", "How much does a bus ticket cost?", "Koliko košta parking?",
             "Gdje provjeravam cijenu pasoša?", "Ne pitam za tu cijenu", "Koliko to košta i kada ide autobus?"].each do |text|
              seed
              @model_input = Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "switch",
                                                             entities: { query: text }, locale: "sr", needs_clarification: false, secondary: nil)
              coordinator.call(message: text, context: @context)
              assert_empty @fee_reads, text
              assert_equal 1, @understood.length, text
            end
          end

          def test_fresh_unreviewed_or_stale_result_never_falls_back_to_cached_fee_or_link
            %w(unreviewed stale).each do |status|
              seed
              @fee_result = Contracts::ReadResult.new(status:, source: { "id" => PROCEDURE_ID, "url" => CURRENT_URL },
                                                     warnings: ["procedure_source_changed_review_required"])
              response = coordinator.call(message: "A gdje provjeravam tu cijenu?", context: @context)
              assert_equal "source_unavailable", response.resolution
              assert_includes response.reply.text, CURRENT_URL
              refute_includes response.reply.text, CURRENT_TEXT
              refute_includes response.reply.text, OLD_URL
              refute_includes response.reply.text, "Old fixture fee"
              assert_nil response.state.fetch("prior_evidence")
              assert_equal 2, @redis.writes
              assert_empty @understood
            end
          end

          def test_deadline_and_cas_failure_never_accept_the_fee_candidate
            %i(before_read after_read conflict).each do |failure|
              seed
              before = @store.read(context: @context)
              @runtime.expire_before_work = failure == :before_read
              @expire_on_read = failure == :after_read
              @redis.reject_write = failure == :conflict
              response = coordinator.call(message: "Koliko to košta?", context: @context)

              assert_equal "unsupported", response.resolution, failure
              refute_includes response.reply.text, CURRENT_TEXT
              refute_includes response.reply.text, CURRENT_URL
              refute_includes response.reply.text, OLD_URL
              assert_equal before, @store.read(context: @context)
              assert_equal 1, @redis.writes
              assert_equal(failure == :before_read ? 0 : 1, @fee_reads.length)
              assert_empty @understood
              assert_nil response.reply.report
              refute response.handoff_completed
            end
          end

          private

          def procedure_fact
            { "id" => PROCEDURE_ID, "kind" => "service_procedure", "text" => "Old fixture fee must not be reused",
              "source_id" => PROCEDURE_ID, "source_label" => "Public procedure owner", "source_url" => OLD_URL, "reviewed_on" => "2026-09-08" }
          end

          def evidence(source: nil, status: "ok", expiry: NOW.to_f + 600, facts: [procedure_fact])
            facts = facts.map { |fact| source ? fact.merge("source_id" => source) : fact }
            read = Contracts::ReadResult.new(status:, facts:)
            captured = PriorEvidence.capture(result: read, facts:, action: "ask_information", topic: "city_service", now: NOW, expires_at: NOW.to_f + 600)
            captured.merge("expires_at" => expiry)
          end

          def seed(prior: evidence, task: "ask_information", topic: "city_service", draft: nil, capabilities: ["public_reads"])
            @context = @context.with(capabilities:)
            @redis = MemoryRedis.new
            @store = StateStore.new(redis: @redis)
            state = @store.empty_state(@context).merge("active_task" => task, "topic" => topic, "draft" => draft,
                                                       "entities" => { "query" => "Izvod iz matične knjige" }, "entity_provenance" => { "query" => "citizen" },
                                                       "prior_evidence" => prior)
            raise "Synthetic seed rejected" unless @store.write(context: @context, state:, expected_version: 0) == :saved

            @fee_reads.clear
            @other_reads.clear
            @understood.clear
            @runtime.clock = 0.0
            @runtime.expire_before_work = false
            @expire_on_read = false
            @model_input = nil
            @fee_result = Contracts::ReadResult.new(status: "ok", facts: [procedure_fact.merge("text" => CURRENT_TEXT, "source_url" => CURRENT_URL)])
          end

          def coordinator
            understanding = lambda do |**arguments|
              @understood << arguments
              @model_input || Contracts::Understanding.clarify(locale: "sr")
            end
            Coordinator.new(understanding:, procedures: @runner, state_store: @store, runtime: @runtime)
          end
        end
      end
    end
  end
end

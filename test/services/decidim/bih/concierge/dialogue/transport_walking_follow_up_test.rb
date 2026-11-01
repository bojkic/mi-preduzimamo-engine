# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class TransportWalkingFollowUpTest < Minitest::Test
          NOW = Time.utc(2026, 9, 9, 12)
          STOP_ID = "transport_stop:0123456789ab"
          STOP_SOURCE = "public_transport_stop_registry"
          URL = "https://www.google.com/maps/dir/?api=1&destination=44.75%2C19.21&travelmode=walking"

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
            attr_accessor :clock

            def initialize = @clock = 0.0

            def call
              budget = TurnBudget.new(timeout: 1.0, clock: -> { clock })
              AdmissionControl::Result.new(status: :admitted, value: yield(budget))
            end
          end

          def setup
            @prior_backend = I18n.backend
            @prior_locales = I18n.available_locales
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "a" * 64,
                                                     capabilities: ["public_reads"], now: NOW)
            @reads = []
            @understood = []
            @runtime = InlineRuntime.new
            @walking_result = Contracts::ReadResult.new(status: "ok", facts: [walking_fact])
            @port = Object.new
            owner = self
            @port.define_singleton_method(:transport_walking_directions) { |**attributes| owner.walking_read(attributes) }
            @port.define_singleton_method(:call) { |**| Contracts::ReadResult.new(status: "empty") }
            @runner = ProcedureRunner.new(read_port: @port, registration_port: ->(**) { raise "Unexpected account read" },
                                          destinations: { report: "/reports/new", account: "/account", support: "/help", neighborhood: "/board" })
            seed
          end

          def teardown
            I18n.backend = @prior_backend
            I18n.available_locales = @prior_locales
          end

          def walking_read(attributes)
            @reads << attributes
            @runtime.clock = 2.0 if @expire_on_read
            @walking_result
          end

          def test_retained_stop_followups_skip_model_and_keep_trip_evidence_without_gps
            ["Kako da pješke stignem do te autobuske stanice?", "Možeš li me uputiti do najbližeg autobuskog stajališta?",
             "Pješke do nabliže stanice?", "Otvori mapu do stanice", "Отвори мапу до станице", "Open the map to the boarding bus stop",
             "Како да пјешке стигнем до те аутобуске станице?",
             "Kako da do tog stajališta dođem pješice?", "Kako mogu do te stanice stići pješke?",
             "Како да до тог стајалишта дођем пјешице?", "Kako do najbližeg stajališta idem pešice?",
             "Daj mi pješačku navigaciju baš do stajališta gdje ulazim u taj autobus.",
             "Pošalji pješačku rutu do polazne stanice", "Покажи ми навигацију до стајалишта гдје улазим у аутобус",
             "Може ли упутство како пјешице до полазног стајалишта?", "Daj mi upute pješke do te stanice",
             "Uputstvo kako pješke do najbliže stanice", "How do I walk to that bus stop?"].each do |text|
              seed
              prior = @store.read(context: @context).fetch("prior_evidence")
              response = coordinator.call(message: text, context: @context)

              assert_equal "answered", response.resolution, text
              assert_includes response.reply.text, URL
              assert_equal STOP_ID, @reads.last.fetch(:stop_id)
              assert_equal %i(context locale stop_id), @reads.last.keys.sort
              assert_equal prior, response.state.fetch("prior_evidence")
              assert_equal({ "area_query" => "Dvorovi" }, response.state.fetch("entities"))
              assert_equal 2, @redis.writes
              assert_empty @understood
              assert_nil response.reply.report
              refute response.handoff_completed
            end
            assert_equal "en", @reads.last.fetch(:locale)
          end

          def test_mixed_negative_and_new_named_stop_questions_do_not_reuse_the_old_stop
            ["Ne želim pješke do te stanice", "Kako da pješke stignem do te stanice i gdje je bolnica?",
             "Pješke do stanice u Janji", "Otvori mapu do stanice u Janji", "Ne otvori mapu do stanice", "Kada ide autobus?",
             "Daj mi pješačku navigaciju do stajališta u Janji", "Kako do bolnice da dođem pješice?",
             "Ne želim pješačku navigaciju do stajališta gdje ulazim u autobus",
             "Daj mi pješačku navigaciju do stajališta gdje ulazim u autobus i objavi prijavu",
             "Može li uputstvo pješice do stanice u Janji", "Ne treba mi uputstvo pješke do stanice",
             "Može li uputstvo do stanice i raspored autobusa"].each do |text|
              seed
              coordinator.call(message: text, context: @context)
              assert_empty @reads, text
              assert_equal 1, @understood.length, text
            end
          end

          def test_missing_expired_stale_wrong_source_and_multiple_stops_do_not_authorize_followup
            [nil, evidence(source: "other_registry"), evidence(status: "stale"), evidence(expiry: NOW.to_f - 1),
             evidence(facts: [walking_fact, walking_fact.merge("id" => "transport_stop:abcdef012345")])].each do |prior|
              seed(prior:)
              coordinator.call(message: "Pješke do te stanice", context: @context)
              assert_empty @reads
              assert_equal 1, @understood.length
            end
          end

          def test_model_entity_stop_id_and_other_active_task_cannot_select_navigation
            seed(prior: nil)
            @model_input = Contracts::Understanding.parse(action: "ask_information", topic: "transport", operation: "continue",
                                                           entities: { reference: STOP_ID }, locale: "sr", needs_clarification: false, secondary: nil)
            coordinator.call(message: "Pješke do te stanice", context: @context)
            assert_empty @reads
            assert_equal 1, @understood.length

            seed(task: "report_problem", topic: "roads")
            coordinator.call(message: "Pješke do te stanice", context: @context)
            assert_empty @reads
          end

          def test_deadline_cas_and_wrong_stop_result_fail_without_accepting_a_navigation_reply
            %i(deadline conflict wrong_stop).each do |failure|
              seed
              @expire_on_read = failure == :deadline
              @redis.reject_write = failure == :conflict
              if failure == :wrong_stop
                @walking_result = Contracts::ReadResult.new(status: "ok", facts: [walking_fact.merge("id" => "transport_stop:abcdef012345")])
              end
              response = coordinator.call(message: "Pješke do te stanice", context: @context)

              assert_equal "unsupported", response.resolution, failure
              refute_includes response.reply.text, URL
              assert_equal 1, @redis.writes
              assert_empty @understood
              @expire_on_read = false
              @runtime.clock = 0.0
            end
          end

          private

          def walking_fact
            { "id" => STOP_ID, "kind" => "transport_navigation", "text" => "Synthetic walking directions",
              "source_id" => STOP_SOURCE, "source_label" => "Synthetic stop registry", "destination" => URL }
          end

          def evidence(source: STOP_SOURCE, status: "ok", expiry: NOW.to_f + 600, facts: [walking_fact])
            facts = facts.map { |fact| fact.merge("source_id" => source) }
            result = Contracts::ReadResult.new(status:, facts:)
            captured = PriorEvidence.capture(result:, facts:, action: "ask_information", topic: "transport", now: NOW, expires_at: NOW.to_f + 600)
            captured.merge("expires_at" => expiry)
          end

          def seed(prior: evidence, task: "ask_information", topic: "transport")
            @redis = MemoryRedis.new
            @store = StateStore.new(redis: @redis)
            state = @store.empty_state(@context).merge("active_task" => task, "topic" => topic,
                                                       "entities" => { "area_query" => "Dvorovi" }, "entity_provenance" => { "area_query" => "citizen" },
                                                       "prior_evidence" => prior)
            raise "Synthetic seed rejected" unless @store.write(context: @context, state:, expected_version: 0) == :saved

            @reads.clear
            @understood.clear
            @model_input = nil
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

# frozen_string_literal: true

require "test_helper"
require "digest"
require "active_support"
require "active_support/notifications"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/understand"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class NewDataReadTopicsTest < Minitest::Test
          TOPICS = %w(air_quality water_levels police sistem48 weather civil_protection bulky_waste budget gazette donation volunteer community participation public_calls
                      facilities rewards health social_welfare agriculture permits education animals).freeze
          NOW = Time.utc(2026, 9, 9, 12)

          class MemoryRedis
            def initialize = @data = {}

            def get(key) = @data[key]

            def eval(script, keys:, argv:)
              raise "Unexpected persistence command" unless script == StateStore::WRITE_SCRIPT

              old = @data[keys.first]
              version = old ? JSON.parse(old).fetch("version") : 0
              return 0 unless version == argv.first

              @data[keys.first] = argv[1]
              1
            end
          end

          class InlineRuntime
            def call
              AdmissionControl::Result.new(status: :admitted, value: yield(TurnBudget.new(timeout: 2)))
            end
          end

          class ClassificationFixture
            attr_accessor :topic, :entities
            attr_reader :calls

            def initialize = @calls = []

            def configured? = true

            def generate_content(**arguments)
              @calls << arguments
              { "action" => "ask_information", "topic" => topic, "entities" => entities || {}, "operation" => "start",
                "needs_clarification" => false, "secondary" => nil, "locale" => "sr" }
            end
          end

          def setup
            @previous_backend = I18n.backend
            @previous_load_path = I18n.load_path
            @previous_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path = [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend = I18n::Backend::Simple.new
            I18n.backend.send(:init_translations)
            @reads = []
            @client = ClassificationFixture.new
            @store = StateStore.new(redis: MemoryRedis.new)
            procedures = ProcedureRunner.new(read_port: lambda { |**args|
              @reads << args
              @read_result
            },
                                             registration_port: ->(**) { raise "Unexpected account action" },
                                             destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" })
            legacy_responder = Object.new
            legacy_responder.define_singleton_method(:respond) { |_| raise "New typed topic reached legacy adapter" }
            @coordinator = Coordinator.new(understanding: Understand.new(client: @client, wall_clock: -> { NOW }), procedures:,
                                           state_store: @store, runtime: InlineRuntime.new,
                                           legacy_secondary: Coordinator::LegacyReadAdapter.new(responder: legacy_responder))
          end

          def teardown
            I18n.backend = @previous_backend
            I18n.load_path = @previous_load_path
            I18n.available_locales = @previous_locales
          end

          def test_every_new_public_topic_crosses_understanding_and_coordinator_into_typed_read_and_retains_source_evidence
            TOPICS.each do |topic|
              @client.topic = topic
              @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact(topic)], source: source,
                                                       checked_at: NOW - 60, warnings: ["source_observation_not_area_status"])
              result = @coordinator.call(message: "Prikaži javne podatke za #{topic}", context: context(topic))
              assert_equal "answered", result.resolution, topic
              assert_equal topic, @reads.last.fetch(:topic)
              assert_includes result.reply.text, "Prepared evidence #{topic}"
              assert_includes result.reply.text, "https://source.example/notice"
              assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_observation_scope", locale: "sr")
              refute result.handoff_completed
              assert_nil result.reply.report
              evidence = @store.read(context: context(topic)).fetch("prior_evidence")
              assert_equal topic, evidence.fetch("topic")
              refute JSON.generate(evidence).include?("Prepared evidence")
              calls = @client.calls.size
              followup = @coordinator.call(message: "Odakle ti to?", context: context(topic))
              assert_includes followup.reply.text, "Public source"
              assert_equal calls, @client.calls.size
            end
            assert(@client.calls.all? { |call| call.fetch(:system_instruction).length <= Understand::MAX_INSTRUCTION_LENGTH })
          end

          def test_understanding_and_rendering_publish_only_bounded_stage_metrics
            observations = []
            subscriber = ActiveSupport::Notifications.subscribe(StageTiming::EVENT) do |*, payload|
              observations << payload
            end
            @client.topic = "air_quality"
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact("air_quality")], source: source)
            result = @coordinator.call(message: "Prikaži javne podatke", context: context("air_quality"))
            assert_equal "answered", result.resolution
            assert_equal(%w(understanding rendering), observations.map { |payload| payload.fetch(:stage) })
            observations.each do |payload|
              assert_equal [:duration_ms, :stage, :status], payload.keys.sort
              assert_equal "completed", payload.fetch(:status)
              assert_operator payload.fetch(:duration_ms), :>=, 0
            end
            assert_raises(RuntimeError) { StageTiming.measure("rendering") { raise "SENSITIVE PROVIDER DETAIL" } }
            assert_equal "failed", observations.last.fetch(:status)
            refute_includes observations.to_json, "SENSITIVE"
          ensure
            ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
          end

          def test_nested_application_deadline_and_review_date_are_rendered_and_survive_date_followup
            @client.topic = "public_calls"
            @read_result = Contracts::ReadResult.new(status: "ok", source:, facts: [fact("public_calls").merge(
              "validity" => { "opens_on" => "2026-09-01", "closes_on" => "2026-09-30" },
              "reviewed_on" => "2026-09-08", "source_published_on" => "2026-09-01"
            )], warnings: ["eligibility_must_be_checked_in_official_call"])
            result = @coordinator.call(message: "Koji javni pozivi su otvoreni?", context: context("public_calls"))
            # Dates are rendered for humans (NOW is 9.9.2026 in Europe/Sarajevo).
            assert_includes result.reply.text, "30.9.2026."
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_eligibility", locale: "sr")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.fact_reviewed_on", locale: "sr", time: "juče")
            followup = @coordinator.call(message: "Za koji datum ovo važi?", context: context("public_calls"))
            assert_includes followup.reply.text, "30.9.2026."
            assert_includes followup.reply.text, "juče"
            refute_match(/\d{4}-\d{2}-\d{2}/, followup.reply.text)
            assert_equal 1, @client.calls.size
          end

          def test_date_only_effective_day_and_planned_end_caveat_survive_rendering_and_date_followup
            @client.topic = "water"
            @client.entities = { "area_query" => "Dvorovi" }
            @read_result = Contracts::ReadResult.new(status: "ok", source:, facts: [fact("water").merge(
              "validity" => { "precision" => "day", "date" => "2026-09-08" }, "starts_at" => nil, "ends_at" => nil
            )], warnings: %w(source_time_is_date_only planned_end_not_confirmed_restoration))
            result = @coordinator.call(message: "Šta je bilo sa vodom u Dvorovima?", context: context("date-only"))
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.fact_service_day", locale: "sr", time: "juče")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_date_only", locale: "sr")
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_planned_end", locale: "sr")
            refute_includes result.reply.text, "00:00"
            evidence = @store.read(context: context("date-only")).fetch("prior_evidence").fetch("facts").first
            assert_equal "2026-09-08", evidence.fetch("service_day"), "stored evidence stays ISO 8601"
            refute evidence.has_key?("starts_at")
            followup = @coordinator.call(message: "Za koji datum ovo važi?", context: context("date-only"))
            assert_includes followup.reply.text, "juče"
            assert_equal 1, @client.calls.size
          end

          def test_non_successful_prepared_reads_never_assert_fixture_facts_or_drift_into_legacy
            %w(empty unavailable unreviewed stale ambiguous).each do |status|
              @client.topic = "air_quality"
              warnings = status == "ambiguous" ? ["measurement_date_required"] : ["partial_source_coverage"]
              @read_result = Contracts::ReadResult.new(status:, source:, warnings:)
              result = @coordinator.call(message: "Kakav je kvalitet vazduha?", context: context("air_quality-#{status}"))
              assert_empty result.fact_ids
              refute_includes result.reply.text, "Prepared evidence"
              assert_equal "air_quality", @reads.last.fetch(:topic)
              refute result.handoff_completed
              assert_equal "clarification", result.resolution if status == "ambiguous"
            end
          end

          def test_new_temporal_and_warning_labels_exist_in_every_supported_locale
            Contracts::LOCALES.each do |locale|
              %w(fact_observed_at fact_reviewed_on fact_source_published_at fact_starts_at fact_ends_at read_warning_observation_scope read_warning_eligibility).each do |key|
                assert I18n.exists?("decidim.bih.dialogue.#{key}", locale), "#{locale}: #{key}"
              end
            end
          end

          private

          def source = { "id" => "public_source", "label" => "Public source", "url" => "https://source.example/notice" }

          def fact(topic) = { "id" => "prepared:#{topic}:1", "kind" => "public_fact", "text" => "Prepared evidence #{topic}", "source_id" => "public_source" }

          def context(topic)
            Contracts::TrustedContext.new(organization_id: 1, conversation_key: Digest::SHA256.hexdigest(topic), now: NOW, capabilities: ["public_reads"])
          end
        end
      end
    end
  end
end

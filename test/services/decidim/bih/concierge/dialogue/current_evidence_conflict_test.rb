# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class CurrentEvidenceConflictTest < Minitest::Test
          NOW = Time.utc(2026, 9, 9, 8)
          Message = Data.define(:text, :dialogue_location)

          def setup
            @previous_backend = I18n.backend
            @previous_load_path = I18n.load_path
            @previous_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path = [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend = I18n::Backend::Simple.new
            I18n.backend.send(:init_translations)
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, now: NOW, capabilities: ["public_reads"])
            @reads = []
            @runner = ProcedureRunner.new(
              read_port: lambda { |**arguments|
                @reads << arguments
                @read_result
              },
              registration_port: ->(**) { raise "Public evidence conflict must not invoke account operations" },
              destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" }
            )
          end

          def teardown
            I18n.backend = @previous_backend
            I18n.load_path = @previous_load_path
            I18n.available_locales = @previous_locales
          end

          def test_both_conflicting_cited_assertions_are_visible_without_selecting_a_winner_in_english_and_cyrillic
            { "en" => ["The provider schedules an outage.", "The provider reports service restored."],
              "sr-Cyrl" => ["Добављач најављује прекид.", "Добављач наводи да је снабдијевање обновљено."] }.each do |locale, texts|
              @read_result = conflict_result(texts)
              result = render(topic: "electricity", locale:)

              assert_equal "source_unavailable", result.resolution, locale
              assert_empty result.fact_ids
              assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_conflicting_facts", locale:)
              texts.each { |text| assert_includes result.reply.text, text }
              @read_result.facts.each { |fact| assert_includes result.reply.text, fact.fetch("source_url") }
              refute result.handoff_completed
              refute result.handoff_offered
              assert_nil result.reply.report
              assert_nil result.state["prior_evidence"]
            end
          end

          def test_measurement_conflict_keeps_both_values_and_their_sources_without_a_current_measurement_claim
            @read_result = conflict_result(["Radalj: 31 cm at 09:00.", "Radalj: 52 cm at 09:00."])
            result = render(topic: "water_levels", locale: "en")

            assert_equal "source_unavailable", result.resolution
            assert_empty result.fact_ids
            assert_equal "water_levels", @reads.last.fetch(:topic)
            assert_includes result.reply.text, "31 cm"
            assert_includes result.reply.text, "52 cm"
            assert_includes result.reply.text, "https://provider.example/assertion-1"
            assert_includes result.reply.text, "https://provider.example/assertion-2"
          end

          def test_ordinary_unreviewed_result_does_not_publish_unsupported_assertions
            @read_result = Contracts::ReadResult.new(status: "unreviewed", facts: [fact(1, "Unverified provider assertion")])
            result = render(topic: "electricity", locale: "en")

            assert_equal "source_unavailable", result.resolution
            assert_empty result.fact_ids
            refute_includes result.reply.text, "Unverified provider assertion"
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.read_warning_conflicting_facts", locale: "en")
          end

          private

          def render(topic:, locale:)
            understanding = Contracts::Understanding.parse(action: "ask_information", topic:, entities: { "area_query" => "MZ Dvorovi" },
                                                           operation: "start", locale:, needs_clarification: false, secondary: nil)
            @runner.call(understanding:, state: StateStore.new.empty_state(@context), context: @context,
                         message: Message.new(text: "Public service information", dialogue_location: nil))
          end

          def conflict_result(texts)
            Contracts::ReadResult.new(status: "unreviewed", facts: texts.map.with_index { |text, index| fact(index + 1, text) },
                                      warnings: ["conflicting_current_facts"], validity: { "conflict" => "conflicting_current_facts" })
          end

          def fact(index, text)
            { "id" => "service_event:#{index}", "kind" => "public_fact", "text" => text,
              "source_id" => "operator", "source_label" => "Provider assertion #{index}", "source_url" => "https://provider.example/assertion-#{index}" }
          end
        end
      end
    end
  end
end

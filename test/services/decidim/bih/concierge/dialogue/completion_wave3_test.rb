# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class CompletionWave3Test < Minitest::Test
          Message = Data.define(:text, :dialogue_location)

          def setup
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += Dir[File.expand_path("../../../../../../config/locales/decidim_bih_dialogue*.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "b" * 64,
                                                     now: Time.utc(2026, 9, 9, 12), capabilities: %w(public_reads))
            @state = StateStore.new.empty_state(@context)
            @runner = ProcedureRunner.new(read_port: ->(**) { @read_result }, registration_port: ->(**) { raise "Unexpected write" },
                                          destinations: { account: "/account", neighborhood: "/board", report: "/reports", support: "/help" })
          end

          def answer(locale: "sr")
            input = Contracts::Understanding.parse(action: "ask_information", topic: "city_service", entities: {}, operation: "start",
                                                   needs_clarification: false, secondary: nil, locale:)
            @runner.call(understanding: input, state: @state, context: @context, message: Message.new("read", nil))
          end

          def notice(id, checked: "2026-09-09T11:00:00Z")
            { "id" => "event:#{id}", "kind" => "city_service_event", "text" => "Notice #{id}: 1 NN izlaz. Unconfirmed source facts. Context #{id}, not coverage.",
              "answer_shape" => "service_event_v1", "notice_body" => "Notice #{id}: 1 NN izlaz.",
              "notice_qualifiers" => { "source_facts_unconfirmed" => "Unconfirmed source facts.", "place_name_context_not_service_coverage" => "Context #{id}, not coverage." },
              "source_id" => "electricity_outages", "source_label" => "Public operator", "source_url" => "https://source.example/notices",
              "checked_at" => checked, "starts_at" => "2026-09-10T07:00:00Z", "ends_at" => "2026-09-10T#{id == 1 ? '11' : '12'}:00:00Z",
              "source_updated_at" => "2026-09-09T09:00:00Z",
              "coverage" => { "requested_relation" => "unknown", "area_slugs" => [] } }
          end

          def test_literal_shared_qualifier_and_provenance_grouping_keeps_individual_evidence
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [notice(1), notice(2)], warnings: ["planned_end_not_confirmed_restoration"])
            reply = answer
            # Times are rendered for humans in Europe/Sarajevo (NOW is 9.9.2026 14:00 there).
            assert_equal 1, reply.reply.text.scan("Unconfirmed source facts.").length
            assert_equal 1, reply.reply.text.scan("https://source.example/notices").length
            assert_equal 1, reply.reply.text.scan("danas u 13:00").length
            %w(1 2).each { |id| assert_includes reply.reply.text, "Context #{id}, not coverage." }
            assert_includes reply.reply.text, "10.9.2026. u 13:00"
            assert_includes reply.reply.text, "10.9.2026. u 14:00"
            assert_equal 2, reply.reply.text.scan("danas u 11:00").length
            refute_match(/\d{4}-\d{2}-\d{2}T/, reply.reply.text)
            assert_equal %w(event:1 event:2), reply.fact_ids
            assert_includes reply.reply.text, I18n.t("decidim.bih.dialogue.read_warning_planned_end", locale: :sr)
          end

          def test_different_source_check_times_are_never_collapsed
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [notice(1), notice(2, checked: "2026-09-09T11:30:00Z")])
            text = answer.reply.text
            assert_equal 2, text.scan("https://source.example/notices").length
            assert_includes text, "danas u 13:00"
            assert_includes text, "danas u 13:30"
          end

          def test_malformed_optional_shape_uses_complete_fallback
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [notice(1).merge("text" => "Complete fallback 1.", "notice_qualifiers" => "not a contract")])
            text = answer.reply.text
            assert_includes text, "Complete fallback 1."
            refute_includes text, "not a contract"
            assert_includes text, "10.9.2026. u 13:00"
          end

          def test_inconsistent_optional_body_cannot_replace_validated_fact_text
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [notice(1).merge("notice_body" => "Unsupported extra assertion")])
            text = answer.reply.text
            refute_includes text, "Unsupported extra assertion"
            assert_includes text, notice(1).fetch("text")
          end

          def test_public_activity_is_not_rendered_as_a_service_notice_and_keeps_limits
            fact = { "id" => "public_meeting:9", "kind" => "neighborhood_activity", "text" => "Public title",
                     "source_id" => "platform_catalog", "source_label" => "Public catalog", "destination" => "/meeting/9",
                     "starts_at" => "2026-09-11T15:00:00Z", "ends_at" => "2026-09-11T17:00:00Z", "coverage" => { "activity_type" => "meeting" } }
            coverage = { "scope" => "public_neighborhood_activities", "area_labels" => ["Area 12"],
                         "activities" => { "area_label" => "Area 12", "starts_at" => "2026-09-09T12:00:00Z", "ends_at" => "2026-09-16T12:00:00Z" } }
            @read_result = Contracts::ReadResult.new(status: "ok", facts: [fact], coverage:,
                                                    warnings: %w(neighborhood_activity_scope_limited neighborhood_activity_participation_on_page))
            starts = { "sr" => "11.9.2026. u 17:00", "sr-Cyrl" => "11.9.2026. у 17:00", "bs" => "11.9.2026. u 17:00",
                       "hr" => "11.9.2026. u 17:00", "en" => "11 Sep 2026, 17:00" }
            Contracts::LOCALES.each do |locale|
              reply = answer(locale:)
              assert_includes reply.reply.text, I18n.t("decidim.bih.dialogue.neighborhood_activities_heading", locale:)
              assert_includes reply.reply.text, I18n.t("decidim.bih.dialogue.neighborhood_activity_type_meeting", locale:)
              refute_includes reply.reply.text, I18n.t("decidim.bih.dialogue.neighborhood_notices_heading", locale:)
              assert_includes reply.reply.text, "/meeting/9"
              assert_includes reply.reply.text, starts.fetch(locale)
              refute_match(/\d{4}-\d{2}-\d{2}T/, reply.reply.text)
              @read_result.warnings.each { |code| assert_includes reply.reply.text, I18n.t("decidim.bih.dialogue.read_warning_#{code}", locale:) }
            end
          end

          def test_public_activity_words_remain_read_only_and_are_not_area_answers
            ["javni sastanak", "volonterske aktivnosti", "projekti zajednice", "public meetings", "volunteer opportunities"].each do |query|
              assert Procedures::Komsiluk::ACTIVITY.match?(Decidim::Bih::Text.fold(query))
              assert_nil Procedures::Komsiluk.area_answer(query)
            end
            assert_equal :board, Procedures::Komsiluk.requested_kind("objavi projekat na tabli")
          end
        end
      end
    end
  end
end

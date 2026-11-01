# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Facts are quoted in their source's language, which is Serbian for
        # every reviewed city source. An English reply says so once, above the
        # fact block, so the English footers are not read as a translation of
        # the body. Serbian, Bosnian and Croatian replies never carry the note.
        class SourceLanguageNoteTest < Minitest::Test
          NOW = Time.utc(2026, 9, 13, 12)
          Message = Data.define(:text, :dialogue_location)
          FACT_TEXT = "Zona 1: 1 KM po satu, radnim danom od 7 do 20 časova."

          def setup
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, now: NOW,
                                                     capabilities: %w(public_reads report_guidance registration_handoff))
            @state = StateStore.new.empty_state(@context)
            @read_result = Contracts::ReadResult.new(
              status: "ok",
              facts: [{ "id" => "tariff:1", "kind" => "parking_tariff", "text" => FACT_TEXT, "source_id" => "parking_tariff" }],
              source: { "id" => "parking_tariff", "label" => "Grad Bijeljina — parking", "url" => "https://source.example/parking" },
              checked_at: NOW - 60
            )
            @runner = ProcedureRunner.new(
              read_port: ->(**) { @read_result },
              registration_port: ->(**) { raise "Unexpected account action" },
              destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" }
            )
          end

          def test_an_english_reply_says_once_that_its_facts_are_in_serbian
            result = run_turn("How much is parking in zone 1?", locale: "en")

            assert_equal "answered", result.resolution
            assert result.reply.text.start_with?("#{note("en")}\n\n"), result.reply.text
            assert_equal 1, result.reply.text.scan(note("en")).size
            assert_includes result.reply.text, FACT_TEXT
            assert_includes result.reply.text, "https://source.example/parking"
          end

          def test_local_language_replies_never_carry_the_note
            %w(sr sr-Cyrl bs hr).each do |locale|
              @state = StateStore.new.empty_state(@context)
              result = run_turn("Koliko košta parking u zoni 1?", locale:)

              assert_equal "answered", result.resolution, locale
              assert_includes result.reply.text, FACT_TEXT, locale
              refute_includes result.reply.text, note("en"), locale
              refute_includes result.reply.text, note(locale), locale
            end
          end

          def test_an_english_reply_without_facts_has_nothing_to_flag
            @read_result = Contracts::ReadResult.new(status: "empty")
            result = run_turn("How much is parking in zone 1?", locale: "en")

            # The fixture read carries no facts, so the turn ends with the "no verified
            # data" refusal. That is "unsupported", not "answered" (Task 9b).
            assert_equal "unsupported", result.resolution
            refute_includes result.reply.text, note("en")
          end

          private

          def note(locale)
            I18n.t("decidim.bih.dialogue.facts_in_source_language", locale:, raise: true)
          end

          def run_turn(text, locale:)
            understanding = Contracts::Understanding.parse(action: "ask_information", topic: "parking", entities: {}, operation: "start",
                                                           locale:, needs_clarification: false, secondary: nil)
            result = @runner.call(understanding:, state: @state, context: @context, message: Message.new(text:, dialogue_location: nil))
            @state = result.state
            result
          end
        end
      end
    end
  end
end

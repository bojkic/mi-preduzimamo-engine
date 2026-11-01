# frozen_string_literal: true

require "test_helper"
require "json"
require "digest"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A conversation with no saved turn answers in the citizen's UI locale.
        # Decidim sets I18n.locale per request from the user's or the
        # organisation's locale, and a Latin first message cannot tell bs, hr
        # and sr apart on its own. A Cyrillic message still wins, and a saved
        # locale is never overridden by the UI.
        class CoordinatorLocaleSeedTest < Minitest::Test
          NOW = Time.utc(2026, 9, 13, 12)
          LATIN_QUESTION = "Prikaži javne podatke za parking"
          CYRILLIC_QUESTION = "Прикажи јавне податке за паркинг"

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

          def setup
            @previous_backend = I18n.backend
            @previous_load_path = I18n.load_path
            @previous_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES + %w(de)
            I18n.load_path = [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend = I18n::Backend::Simple.new
            I18n.backend.send(:init_translations)
            @store = StateStore.new(redis: MemoryRedis.new)
            @seen_locales = []
            # The real Understand keeps a saved Latin locale for a clearly Latin
            # message and answers a Cyrillic message in Cyrillic.
            understanding = lambda do |message:, state:, **|
              @seen_locales << state.fetch("locale")
              locale = message.to_s.match?(/\p{Cyrillic}/) ? "sr-Cyrl" : state.fetch("locale")
              Contracts::Understanding.parse(action: "ask_information", topic: "parking", entities: {}, operation: "start",
                                             needs_clarification: false, secondary: nil, locale:)
            end
            procedures = ProcedureRunner.new(
              read_port: ->(**) { Contracts::ReadResult.new(status: "empty") },
              registration_port: ->(**) { raise "Unexpected account action" },
              destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" }
            )
            @coordinator = Coordinator.new(understanding:, procedures:, state_store: @store, runtime: InlineRuntime.new)
          end

          def teardown
            I18n.backend = @previous_backend
            I18n.load_path = @previous_load_path
            I18n.available_locales = @previous_locales
          end

          def test_a_first_latin_message_is_answered_in_the_ui_locale
            %w(bs hr en).each do |locale|
              @seen_locales.clear
              result = I18n.with_locale(locale) { @coordinator.call(message: LATIN_QUESTION, context: context(locale)) }

              # The fixture read carries no facts, so the turn ends with the "no verified
              # data" refusal. That is "unsupported", not "answered" (Task 9b).
              assert_equal "unsupported", result.resolution, locale
              assert_equal [locale], @seen_locales, "the understanding must see the seeded locale (#{locale})"
              assert_equal locale, result.state.fetch("locale")
              assert_equal locale, @store.read(context: context(locale)).fetch("locale"), "the seeded locale is saved (#{locale})"
              assert_equal I18n.t("decidim.bih.dialogue.no_match", locale:, raise: true), result.reply.text.lines.first.strip
            end
          end

          def test_a_cyrillic_first_message_wins_over_a_latin_ui_locale
            result = I18n.with_locale(:bs) { @coordinator.call(message: CYRILLIC_QUESTION, context: context("cyr")) }

            assert_equal ["sr-Cyrl"], @seen_locales
            assert_equal "sr-Cyrl", result.state.fetch("locale")
          end

          def test_a_ui_locale_milica_does_not_speak_falls_back_to_serbian
            result = I18n.with_locale(:de) { @coordinator.call(message: LATIN_QUESTION, context: context("de")) }

            assert_equal ["sr"], @seen_locales
            assert_equal "sr", result.state.fetch("locale")
          end

          def test_a_saved_locale_is_never_overridden_by_the_ui_locale
            first = I18n.with_locale(:sr) { @coordinator.call(message: LATIN_QUESTION, context: context("saved")) }
            assert_equal "sr", first.state.fetch("locale")

            second = I18n.with_locale(:bs) { @coordinator.call(message: "#{LATIN_QUESTION} u centru", context: context("saved")) }

            assert_equal %w(sr sr), @seen_locales
            assert_equal "sr", second.state.fetch("locale")
          end

          def test_the_fresh_state_itself_still_defaults_to_serbian
            state = I18n.with_locale(:bs) { @store.empty_state(context("fresh")) }

            assert_equal "sr", state.fetch("locale")
            assert_equal 0, state.fetch("version")
          end

          private

          def context(key)
            Contracts::TrustedContext.new(organization_id: 1, conversation_key: Digest::SHA256.hexdigest(key), now: NOW,
                                          capabilities: %w(public_reads report_guidance registration_handoff))
          end
        end
      end
    end
  end
end

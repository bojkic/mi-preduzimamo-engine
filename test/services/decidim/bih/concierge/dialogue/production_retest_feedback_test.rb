# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ProductionRetestFeedbackTest < Minitest::Test
          # Consumed diagnostic cases: these pin functionality, not a fresh quality score.
          QUESTIONS = {
            "Šta radi dugme Nije korisno ispod tvog odgovora?" => "civic_feedback",
            "Ako kliknem Korisno, dobijam li bodove?" => "civic_feedback_points",
            "Да ли Нije korisno брише моју претходну поруку?" => "civic_feedback_deletion",
            "Mogu li promijeniti ocjenu odgovora?" => "civic_feedback_change",
            "Da li ocjenjujem Milicu ili gradsku službu?" => "civic_feedback_target",
            "Da li Korisno znači da ste riješili moj komunalni problem?" => "civic_feedback_report",
            "Ko vidi moju ocjenu Nije korisno?" => "civic_feedback_privacy",
            "Означио сам одговор некорисним." => "civic_feedback_target",
            "Zašto nema ocjene na ovoj Instagram poruci?" => "civic_feedback_controls",
            "Ako napišem korisno u chatu, je li ocjena sačuvana?" => "civic_feedback_typed",
            "Kako da popravim netačan odgovor Milice?" => "civic_feedback_repair",
            "Mislim baš ocjenu odgovora." => "civic_feedback",
            "Ne ocjenjujem gradsku službu nego tvoj odgovor." => "civic_feedback_target"
          }.freeze

          def setup
            @store = StateStore.new(redis: Characterisation::FakeRedis.new)
            @context = Contracts::TrustedContext.new(
              organization_id: 1, conversation_key: "a" * 64, actor_id: nil,
              account_state: "anonymous", capabilities: Characterisation::CAPABILITIES, now: Characterisation::NOW
            )
          end

          def test_all_feedback_facets_run_without_a_model_or_account_read
            QUESTIONS.each do |question, subject|
              result = answer(question)
              assert_equal "answered", result.resolution, question
              assert_equal subject, result.state.dig(AnswerContext::KEY, "subject"), question
              refute_match(/translation missing|%\{/, result.reply.text, question)
              refute result.handoff_offered, question
            end
          end

          def test_complete_rating_conversations_keep_the_changed_facet
            followups = [
              ["Da li to odmah šalje prijavu gradu?", "civic_feedback_report"],
              ["Mislim baš ocjenu odgovora.", "civic_feedback"],
              ["Шта се заправо оцјењује?", "civic_feedback_target"],
              ["Ne izmišljaj dugme ako nije dostupno.", "civic_feedback_change"],
              ["Mislim na Korisno ispod poruke.", "civic_feedback_target"],
              ["Odgovor može pomoći i bez rješenja problema.", "civic_feedback_report"],
              ["Objasni samo provjerenu privatnost ocjene.", "civic_feedback_privacy"],
              ["Да ли се тиме аутоматски отвара налог?", "civic_feedback_account"],
              ["Može li tekstualna riječ zamijeniti klik?", "civic_feedback_typed"],
              ["Razlikuj poruku od klika.", "civic_feedback_typed"]
            ]
            QUESTIONS.keys.first(10).zip(followups).each do |first, (followup, expected)|
              @store = StateStore.new(redis: Characterisation::FakeRedis.new)
              assert_equal "answered", answer(first).resolution, first
              result = answer(followup)
              assert_equal "answered", result.resolution, followup
              assert_equal expected, result.state.dig(AnswerContext::KEY, "subject"), followup
              refute_match(/translation missing|%\{/, result.reply.text, followup)
              refute result.handoff_offered, followup
            end
          end

          def test_feedback_privacy_changes_facet_after_rating_change_help
            answer("Mogu li promijeniti ocjenu odgovora?")
            result = answer("Ko vidi moju ocjenu?")
            assert_equal "civic_feedback_privacy", result.state.dig(AnswerContext::KEY, "subject")
            assert_includes result.reply.text, "ovlašćene osobe"
          end

          def test_cold_restatement_recovers_wrong_account_and_rewards_subjects
            %w(account rewards).each do |topic|
              @store = StateStore.new(redis: Characterisation::FakeRedis.new)
              seeded = @store.empty_state(@context).merge("active_task" => "ask_information", "topic" => topic)
              assert_equal :saved, @store.write(context: @context, state: seeded, expected_version: 0)
              result = answer("Mislim baš ocjenu odgovora.")
              assert_equal "civic_feedback", result.state.dig(AnswerContext::KEY, "subject")
              assert_includes result.reply.text, "privatni pregled"
              assert_empty result.fact_ids
            end
          end

          def test_feedback_is_not_a_school_grade_or_a_substantive_correction
            ["Kako da promijenim ocjenu iz matematike?", "Ko vidi moju ocjenu gradske službe?", "Zašto nema ocjene iz matematike?",
             "Зашто нема оцјене из математике?",
             "Није корисно: не требам награде, објасни како се бодови зарађују.",
             "Nije korisno: ne trebam nagrade, objasni kako se bodovi zarađuju.",
             "Nije korisno, mislio sam prvi autobus nakon 13 časova.",
             "Nije korisno; kako se koristi SMS parking?"].each do |question|
              assert_nil PublicInformation.card(question), question
            end
            assert_equal "civic_feedback", PublicInformation.card("What does Not helpful mean?")&.name
          end

          def test_reviewed_copy_matches_rating_write_and_widget_contracts
            Characterisation.with_locales do
              privacy = PublicInformation.answer(PublicInformation::FEEDBACK_FACETS.fetch("privacy"), locale: "sr")
              assert_includes privacy, "ovlašćene osobe"
              assert_includes privacy, "lični podaci"
              assert_includes privacy, "ne povezuje"
              change = PublicInformation.answer(PublicInformation::FEEDBACK_FACETS.fetch("change"), locale: "sr")
              assert_includes change, "ne možeš promijeniti"
              assert_includes change, "nije uspjelo"
              PublicInformation::FEEDBACK_FACETS.each_value do |card|
                Contracts::LOCALES.each do |locale|
                  refute_match(/translation missing|%\{/, PublicInformation.answer(card, locale:))
                end
              end
            end
          end

          def test_missing_otp_and_balance_donation_corrections_choose_current_subject
            ["Ne, nalog već imam; ne stiže mi kod.", "Не стиже ми код за налог."].each do |question|
              assert_equal "message_missing", AccountQuestion.facet(question)
              assert_equal "account", CivicQuestion.classify(question)&.fetch(:topic)
              result = answer(question)
              assert_equal "answered", result.resolution
              assert_match(/(?:novo slanje|ново слање)/, result.reply.text)
            end
            balance = CivicQuestion.classify("Nisam pitao za kupovinu, koliko bodova imam?")
            assert_equal "balance", balance&.dig(:entities, "category")
            donation = "Mislio sam donirati projektu, ne glasati."
            assert_nil PublicInformation.card(donation)
            assert_equal "organizacija", CivicQuestion.classify(donation)&.dig(:entities, "category")
          end

          def test_report_guidance_and_comparison_cover_both_products
            first = answer("Kome da prijavim rupu na trotoaru kod parka, samo mi objasni postupak.")
            assert_equal "report_how_to", first.state.dig(AnswerContext::KEY, "subject")
            second = answer("Ne šalji ništa, zanima me nadležnost.")
            assert_equal "report_responsibility", second.state.dig(AnswerContext::KEY, "subject")
            assert_includes second.reply.text, "nisam ništa poslala"
            comparison = answer("Која је разлика између Ми и Систем48 пријаве?")
            assert_equal "report_sistem48_comparison", comparison.state.dig(AnswerContext::KEY, "subject")
            assert_includes comparison.reply.text, "МИ"
            assert_includes comparison.reply.text, "Систем 48"
            result = answer("Да ли је одговор Милice већ послата пријава?")
            assert_equal "report_guidance_only", result.state.dig(AnswerContext::KEY, "subject")
          end

          def test_repair_followup_never_returns_to_registration
            answer("Kako da popravim netačan odgovor Milice?")
            result = answer("Ne tražim registraciju.")
            assert_equal "civic_feedback_repair", result.state.dig(AnswerContext::KEY, "subject")
            assert_equal "answered", result.resolution
          end

          def test_responsibility_followup_keeps_no_deadline_no_submission_contract
            first = answer("Samo dvije rečenice: ko je odgovoran za moju prijavu?")
            assert_equal "report_responsibility", first.state.dig(AnswerContext::KEY, "subject")
            second = answer("Nemoj obećati datum odgovora.")
            assert_equal "answered", second.resolution
            assert_includes second.reply.text, "ne mogu obećati datum"
            assert_includes second.reply.text, "nisam ništa poslala"
          end

          def test_brevity_on_integrity_card_uses_reviewed_short_copy
            first = answer("Da li bodovi utiču na glasanje?")
            second = answer("Kratko i jasno odvoji bodove od glasa.")
            assert_equal "answered", second.resolution
            assert_operator second.reply.text.length, :<, first.reply.text.length
            assert_includes second.reply.text, "Jedna osoba ima jedan glas"
            assert_includes second.reply.text, PublicInformation.rules_url
          end

          def test_corrected_earning_question_is_a_read_not_feedback_help
            question = "Nije korisno: ne trebam nagrade, objasni kako se bodovi zarađuju."
            assert_nil PublicInformation.card(question)
            assert_equal "earn", CivicQuestion.classify(question)&.dig(:entities, "category")
            assert_nil CivicQuestion.classify("Ne objasni kako se bodovi zarađuju.")
          end

          def test_known_feedback_and_form_controls_act_on_the_followup
            first = answer("Kako da označim Nije korisno ako ne vidim dugme?")
            second = answer("Mogu li samo napisati šta je pogrešno?")
            assert_equal "civic_feedback_description", second.state.dig(AnswerContext::KEY, "subject")
            assert_match(/\ADa\./, second.reply.text)
            assert_operator second.reply.text.length, :<, first.reply.text.length
            refute_equal first.reply.text, second.reply.text

            answer("Kako da prijavim rupu na cesti?")
            link = answer("Ne vidim dugme koje pominješ. Pošalji mi link koji mogu otvoriti iz Messengera.")
            assert_equal "report_form_link", link.state.dig(AnswerContext::KEY, "subject")
            assert_includes link.reply.text, ReportGuidance.new_report_url
            assert_includes link.reply.text, "nije poslata"
          end

          def test_live_otp_delivery_failure_and_elliptical_followup
            first = answer("Kod za prijavu mi nije stigao.")
            assert_equal "answered", first.resolution
            assert_includes first.reply.text, "zatraži novo slanje"
            second = answer("Šta da uradim ako poruka nikako ne dolazi?")
            assert_equal "answered", second.resolution
            assert_includes second.reply.text, "zatraži novo slanje"
            assert_includes second.reply.text, "ne šaljem poruke ni kodove"
            assert_nil second.reply.report
          end

          def test_instruction_channel_correction_then_named_stop_and_journey_switch
            reads = []
            reader = lambda do |**arguments|
              reads << arguments
              if arguments[:entities]["category"] == "stop_navigation"
                if arguments[:entities]["stop"]
                  Contracts::ReadResult.new(status: "ok", facts: [{ "id" => "nas", "kind" => "transport_navigation",
                    "source_id" => "public_transport_stop_registry", "source_label" => "Test registry", "destination" => "https://example.test/map?stop=nas",
                    "text" => "Stajalište Bijeljina (NAS). Položaj je približan. Mapa: https://example.test/map?stop=nas" }])
                else
                  Contracts::ReadResult.new(status: "ambiguous", warnings: ["transport_navigation_stop_required"])
                end
              else
                Contracts::ReadResult.new(status: "empty")
              end
            end
            first = answer("Na WhatsAppu mi pošalji uputstvo za dolazak do stanice.", read_port: reader)
            assert_equal "clarification", first.resolution
            assert_includes first.reply.text, "nisam poslala poruku"
            assert_equal "stop", first.state["pending_slot"]
            second = answer("Ne šalji poruku, samo mi ovdje napiši uputstvo.", read_port: reader)
            assert_equal "clarification", second.resolution
            assert_includes second.reply.text, "uputstvo pišem ovdje"
            third = answer("Nova autobuska stanica.", read_port: reader)
            assert_equal "answered", third.resolution, [third.reply.text, third.state, reads].inspect
            assert_equal "stop_navigation", reads.last[:entities]["category"]
            assert_equal "Nova autobuska stanica.", reads.last[:entities]["stop"]
            assert_includes third.reply.text, "https://example.test/map?stop=nas"
            journey = ->(**) { Contracts::Understanding.parse(action: "ask_information", topic: "transport",
              entities: { "query" => "Koji autobus od NAS do Janje?", "category" => "stop_navigation" },
              operation: "continue", needs_clarification: false, secondary: nil, locale: "sr") }
            answer("Koji autobus od NAS do Janje?", read_port: reader, understanding: journey)
            refute_equal "stop_navigation", reads.last[:entities]["category"]
          end

          def test_generic_missing_message_requires_existing_code_recovery_context
            state = @store.empty_state(@context)
            message = "Šta da uradim ako poruka nikako ne dolazi?"
            refute AccountQuestion.missing_message_follow_up?(message, state)
            state = state.merge("active_task" => "ask_information", "topic" => "account", "entities" => { "query" => "Kako da se registrujem?" })
            refute AccountQuestion.missing_message_follow_up?(message, state)
            state["entities"]["query"] = "Kod za prijavu mi nije stigao."
            assert AccountQuestion.missing_message_follow_up?(message, state)
            refute AccountQuestion.missing_message_follow_up?(message, state.merge("draft" => { "reference" => "draft" }))
            refute TransportQuestionRoute.navigation_instruction?("Na WhatsAppu mi pošalji potvrdu prijave.")
          end

          private

          def answer(text, read_port: nil, understanding: nil)
            Characterisation.with_locales do
              Coordinator.new(
                understanding: understanding || ->(**) { raise "No model call is allowed for this current question" },
                procedures: ProcedureRunner.new(
                  read_port: read_port || Characterisation::RecordingReadPort.new({}, []),
                  registration_port: ->(**) { Characterisation::DEFAULT_HANDOFF },
                  destinations: Characterisation::DESTINATIONS
                ), state_store: @store, runtime: Characterisation::InlineRuntime.new
              ).call(message: Characterisation::Message.new(text:, conversation_context: [], dialogue_location: nil), context: @context)
            end
          end
        end
      end
    end
  end
end

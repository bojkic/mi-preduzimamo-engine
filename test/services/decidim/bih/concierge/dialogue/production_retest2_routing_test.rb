# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../support/decidim/bih/dialogue_characterisation"
require_relative "../../../../../../app/services/decidim/bih/concierge/web_message"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ProductionRetest2RoutingTest < Minitest::Test
          def setup
            @store = StateStore.new(redis: Characterisation::FakeRedis.new)
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64,
              capabilities: Characterisation::CAPABILITIES, now: Characterisation::NOW)
            @reads = []
            @handoffs = []
          end

          def test_report_complaint_is_not_a_rating_question
            ["To nije korisno, ne pitam kako napraviti novu prijavu.",
             "То није корисно, не питам како направити нову пријаву.",
             "To nije korisno. Pitam za status prijave",
             "Nije korisno — treba mi broj za prvu zonu",
             "To nije korisno ne pitam kako napraviti novu prijavu"].each do |text|
              assert_nil PublicInformation.card(text)
            end
            first = answer("Gdje su moja prijavljena oštećenja?")
            assert_equal "report_own", first.state.dig(AnswerContext::KEY, "subject")
            second = answer("To nije korisno, ne pitam kako napraviti novu prijavu.")
            assert_equal "report_own_recovery", second.state.dig(AnswerContext::KEY, "subject")
            assert_includes second.reply.text, "postojeću prijavu"
            assert_includes second.reply.text, "prijave-pronadji"
            refute_includes second.reply.text, "Dugmad"
            assert_empty @reads
          end

          def test_missing_report_reference_does_not_become_a_missing_phone_code
            first = answer("Želim provjeriti status prijave.")
            assert_equal "reference", first.state["pending_slot"]
            second = answer("Nemam njen broj kod sebe.")
            assert_equal "report_own_recovery", second.state.dig(AnswerContext::KEY, "subject")
            assert_equal "report_status", second.state["active_task"]
            refute_includes second.reply.text, "SMS"
            assert_empty @handoffs
          end

          def test_signed_in_report_correction_rechecks_the_scoped_reader
            @context = @context.with(actor_id: 7, account_state: "registered")
            answer("Gdje su moja prijavljena oštećenja?")
            answer("To nije korisno, ne pitam kako napraviti novu prijavu.")
            assert_equal 2, @reads.length
            assert @reads.all? { |read| read[:action] == "report_status" && read[:context].actor_id == 7 && read[:context].organization_id == 1 }
            assert_empty @handoffs
          end

          def test_account_correction_selects_phone_verification
            first = answer("Kako znam da li sam registrovan?")
            assert_includes first.reply.text, "To ne znači da nalog ne postoji"
            second = answer("Nije korisno: već imam nalog, treba mi provjera broja.")
            assert_equal "handoff", second.resolution
            assert_equal "verification", @handoffs.last[:action]
            assert_empty @reads
          end

          def test_channel_claims_are_not_trusted_identity_or_link_actions
            ["Pišem preko Messengera; jesi li sad povezana s mojim MI nalogom?",
             "Samo ime na Facebooku nije dokaz mog naloga.",
             "Kažem da sam na Instagramu, ali otvorio sam web chat.",
             "Prilagodi se stvarnom kanalu."].each do |text|
              reply = answer(text)
              assert_equal "answered", reply.resolution
              assert_includes reply.reply.text, "Ovo je web razgovor"
              assert_includes reply.reply.text, "nemam potvrđen pristup"
              refute reply.handoff_offered
            end
            @context = @context.with(actor_id: 7, account_state: "registered")
            present = answer("Prilagodi se stvarnom kanalu.")
            assert_includes present.reply.text, "platforma je potvrdila pristup"
            assert_includes present.reply.text, "nisam povezala"
            assert_empty @handoffs
            assert_empty @reads
          end

          def test_without_points_vote_rule_has_correct_polarity_and_continuation
            first = answer("Može li se glasati bez bodova?")
            assert_match(/\ADa/, first.reply.text)
            assert_includes first.reply.text, "ostali uslovi"
            second = answer("Samo pravilo me zanima, ne stanje naloga.")
            assert_equal "civic_vote_without_points", second.state.dig(AnswerContext::KEY, "subject")
            assert_includes second.reply.text, "Jedna osoba ima jedan glas"
            assert_empty @reads
          end

          def test_container_procedure_and_glass_disposal_keep_the_requested_scope
            first = answer("Ne gori ništa; kome prijavljujem stari oštećeni kontejner?")
            assert_equal "report_how_to", first.state.dig(AnswerContext::KEY, "subject")
            second = answer("To je pitanje o postupku.")
            assert_equal "report_how_to", second.state.dig(AnswerContext::KEY, "subject")
            assert_includes second.reply.text, "prijave/new"
            answer("Ne šaljem prijavu; samo pitam gdje se odlaže staklo.")
            assert_equal "waste", @reads.last[:topic]
            assert_includes @reads.last[:entities]["query"], "staklo"
            assert_empty @handoffs
          end

          def test_declining_catalogue_and_closing_do_not_cancel_or_ask_again
            answer("Šta je trka komšiluka?")
            scope = answer("Ne želim katalog nagrada.")
            assert_equal "civic_race_scope", scope.state.dig(AnswerContext::KEY, "subject")
            refute_match(/odustali|Šta želiš/, scope.reply.text)
            answer("Hvala, dovoljno je.")
            close = answer("Ne treba novo objašnjenje niti pitanje.")
            assert_equal "U redu.", close.reply.text
            refute_equal "cancelled", close.resolution
          end

          def test_location_hints_without_task_do_not_assume_transport_or_account
            ["Moja približna lokacija je gradski trg.", "ГПС није доступан у овој поруци.",
             "Могу написати улицу и оријентир."].each do |text|
              result = answer(text)
              assert_equal "answered", result.resolution
              assert_nil result.state["active_task"]
              folded = Text.fold(result.reply.text)
              assert_includes folded, "nije obavezan"
              assert_includes folded, "za sta zelis"
              refute_includes folded, "nalog"
            end
            assert_empty @reads
            assert_empty @handoffs
            turn = Struct.new(:text, :state).new("GPS nije dostupan.", { "active_task" => "ask_information", "topic" => "transport" })
            assert_nil LocationHelpStage.result_for(turn)
            turn.state = { "draft" => { "reference" => "opaque" } }
            assert_nil LocationHelpStage.result_for(turn)
          end

          def test_rating_help_and_report_correction_paraphrases_keep_their_scope
            refute_nil PublicInformation.card("Šta znači dugme Nije korisno?")
            answer("Gdje su moja prijavljena oštećenja?")
            result = answer("To nije korisno. Pitam za status prijave")
            assert_equal "report_own_recovery", result.state.dig(AnswerContext::KEY, "subject")
            ["Nemam broj prijave", "Nemam njen broj"].each do |text|
              result = answer(text)
              assert_equal "report_own_recovery", result.state.dig(AnswerContext::KEY, "subject")
              refute_includes result.reply.text, "SMS"
            end
          end

          def test_selected_boarding_stop_navigation_qualifiers_are_recognised
            coordinator = Coordinator.allocate
            ["Пошаљи навигацију до изабране улазне станице.",
             "Pošalji navigaciju do odabrane ulazne stanice."].each do |text|
              assert coordinator.send(:walking_stop_request?, WebMessage.new(text)), text
            end
            refute coordinator.send(:walking_stop_request?, WebMessage.new("Ne šalji navigaciju do izabrane stanice."))
          end

          def test_unseen_channel_and_identity_paraphrases_use_current_trusted_context
            ["Da li ovaj razgovor na Viberu ima pristup mom MI nalogu?",
             "Jesam li ovdje na Messengeru prijavljen na MI nalog?",
             "Preko kojeg kanala razgovaramo?",
             "Koji je stvarni kanal ovog razgovora?",
             "Nadimak na Instagramu ne dokazuje moj identitet.",
             "Ime na Viberu ne potvrđuje moj MI nalog.",
             "Pominjem Viber, ali koristim web chat.",
             "Rekla sam Messenger, a zapravo pišem na Instagramu."].each do |text|
              assert TrustedConversationStage.question?(text), text
              result = answer(text)
              assert_equal "answered", result.resolution, text
              assert_includes result.reply.text, "Ovo je web razgovor"
              assert_includes result.reply.text, "nemam potvrđen pristup"
            end
            assert_empty @reads
            assert_empty @handoffs
          end

          def test_channel_keyword_does_not_take_substantive_tasks_or_controls
            ["Prijavi rupu iz poruke na Messengeru.",
             "Na Viberu mi pošalji status prijave.",
             "Poveži moj Instagram i MI nalog.",
             "Potvrdi slanje prijave preko Messengera.",
             "Otkaži povezivanje mog naloga na Viberu.",
             "Kako da dobijem kod za prijavu na web chatu?",
             "Da li mogu podnijeti prijavu preko Messengera?",
             "Da li dobijam nagradu ako sam prijavljen na MI nalog preko Vibera?",
             "Da li mogu ocijeniti odgovor ako sam prijavljen na MI nalog preko Messengera?",
             "Pominjem Instagram ali kako da pošaljem fotografiju na web chat?"].each do |text|
              refute TrustedConversationStage.question?(text), text
            end
          end

          def test_gps_unavailable_paraphrases_remain_generic
            ["GPS ne radi na mom telefonu.", "Lokacija je isključena."].each do |text|
              result = answer(text)
              assert_equal "answered", result.resolution
              assert_includes result.reply.text, "GPS nije obavezan"
              assert_nil result.state["active_task"]
            end
          end

          private

          def answer(text)
            Characterisation.with_locales do
              Coordinator.new(
                understanding: ->(**) { raise "This explicit question must not call the model" },
                procedures: ProcedureRunner.new(
                  read_port: ->(**args) { @reads << args; Contracts::ReadResult.new(status: "empty", warnings: args[:action] == "report_status" ? ["no_owned_reports"] : []) },
                  registration_port: ->(**args) { @handoffs << args; Characterisation::DEFAULT_HANDOFF },
                  destinations: Characterisation::DESTINATIONS
                ), state_store: @store, runtime: Characterisation::InlineRuntime.new
              ).call(message: WebMessage.new(text), context: @context)
            end
          end
        end
      end
    end
  end
end

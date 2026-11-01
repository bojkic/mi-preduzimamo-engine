# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/pre_model_stages"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Task 5 — the report meta-questions. Each case names the rated
        # conversation it closes; the transcripts are in
        # docs/audits/2026-09-14-milica-conversation-review/independent-review/.
        class ReportGuidanceTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 10, 30)
          Message = Data.define(:text)

          def setup
            @original_load_path = I18n.load_path.dup
            @original_available_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += %w(decidim_bih_dialogue.yml sr.yml sr-Cyrl.yml bs.yml hr.yml en.yml).map do |file|
              File.expand_path("../../../../../../config/locales/#{file}", __dir__)
            end
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "b" * 64, now: NOW)
            @state = StateStore.new.empty_state(@context)
          end

          def teardown
            I18n.load_path = @original_load_path
            I18n.available_locales = @original_available_locales
            I18n.backend.reload!
          end

          # Everything the stage may reach, with every seam but the retention
          # hook set to raise. The retention hook itself defaults to
          # +Support::NO_RETENTION+, which hands the state straight back — so
          # "a card writes no conversation state" below still asserts exactly
          # what it always did, about the TASK state.
          def support(retain_answer: PreModelStages::NO_RETENTION)
            raising = ->(*, **) { raise "stage support reached" }
            PreModelStages::Support.new(
              procedures: nil, cancelled: ->(*) { false }, prior_evidence_kind: ->(*) {},
              accept: raising, unavailable: raising, resume_nothing: raising,
              resume_with_nothing_suspended: ->(*) { false }, walking_stop_request: ->(*) { false },
              retain_answer:
            )
          end

          def turn(text, state: @state, context: @context, **)
            PreModelStages::Turn.new(message: Message.new(text:), context:, state:, support: support(**))
          end

          def answer(text, **)
            ReportGuidanceStage.result_for(turn(text, **))
          end

          # The attributes the stage tried to retain, with the state left
          # exactly as it was so the rest of the assertions are unaffected.
          def retention_for(text, **)
            captured = []
            recorder = lambda do |state:, **attributes|
              # +context+ is the seam's own argument, not something the stage
              # chose to retain; only the attributes it passed are the subject.
              captured << attributes.except(:context)
              state
            end
            result = ReportGuidanceStage.result_for(turn(text, retain_answer: recorder, **))
            [result, captured.last]
          end

          def test_basic_report_instructions_and_sistem48_explanation_are_public_help
            result = answer("Kako da prijavim rupu na putu?")
            assert_equal "answered", result.resolution
            assert_includes result.reply.text, "prijave/new"
            assert_nil result.reply.report

            overview = answer("Šta je Sistem 48?")
            assert_equal "answered", overview.resolution
            assert_includes overview.reply.text, "odgovor"
            assert_includes overview.reply.text, "ne popravka"
            refute_match(/\ANe[.]/, overview.reply.text)
            assert_nil answer("Prikaži javne podatke za Sistem48")
            assert_nil answer("Kako da prijavim kvar na telefonu?")
            assert_nil answer("Kako da prijavim problem na mom telefonu?")
          end

          def test_report_how_to_after_channel_or_topic_context_stays_public_guidance
            ["Pišem ti preko Facebook Messengera. Kako da prijavim rupu na putu?",
             "Sad drugo pitanje: kako da prijavim neispravnu rasvjetu?",
             "Пишем са телефона. Како да пријавим смеће поред пута?",
             "Ne vidim dugme. Gdje da prijavim problem sa rasvjetom?",
             "Ne znam kako da prijavim rupu na ulici.",
             "Kako da prijavim rupu kod autobuske stanice?",
             "Javljam se iz Instagram poruka. Želim da prijavim neispravnu uličnu rasvjetu, kako?"].each do |text|
              result = answer(text)
              refute_nil result, text
              assert_equal "report_guidance", result.reply.answer_intent
              assert_includes result.reply.text, "prijave/new"
              assert_nil result.reply.report
              assert_equal @state, result.state
            end

            ["Ne pitam kako da prijavim rupu na putu, nego kada ide autobus",
             "Pišem preko Messengera. Kako da prijavim kvar na telefonu?",
             "Kako da prijavim problem sa lozinkom na nalogu?",
             "Znam kako da prijavim rupu. Kada ide autobus?",
             "Objasnili ste kako da prijavim rupu, ali sad pitam za autobus."].each do |text|
              assert_nil answer(text), text
            end
          end

          def test_form_link_follow_up_requires_unexpired_public_form_instructions
            @state[AnswerContext::KEY] = AnswerContext.capture(kind: "report_card", subject: "report_how_to",
                                                               anchor: "Kako da prijavim rupu?", now: NOW, state_expires_at: @state["expires_at"])
            query = "Ne vidim dugme koje pominješ. Pošalji mi link koji mogu otvoriti iz Messengera."
            result = answer(query)
            refute_nil result
            assert_includes result.reply.text, "prijave/new"
            assert_nil result.reply.report
            assert_equal @state, result.state
            assert_nil ReportGuidanceStage.link_follow_up(turn("Pošalji mi link za tuđu prijavu"))
            assert_nil answer(query, state: @state.merge("active_task" => "report_problem"))
            later = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "b" * 64, now: NOW + AnswerContext::TTL + 1)
            assert_nil answer(query, context: later)
            assert_nil answer(query, state: @state.merge(AnswerContext::KEY => nil))
          end

          def test_submission_question_after_form_guidance_requires_no_model_or_receipt
            @state[AnswerContext::KEY] = AnswerContext.capture(kind: "report_card", subject: "report_how_to",
                                                               anchor: "Kako da prijavim rupu?", now: NOW, state_expires_at: @state["expires_at"])
            ["Da li si već poslala prijavu gradu ili moram još nešto uraditi?",
             "Jesi li podnijela moju prijavu?", "Have you already submitted my report?"].each do |query|
              result = answer(query)
              refute_nil result, query
              assert_equal "answered", result.resolution
              assert_includes result.reply.text, "linka"
              assert_includes result.reply.text, "prijave/new"
              assert_nil result.reply.report
              assert_empty result.fact_ids
              refute result.handoff_completed
              assert_equal @state, result.state
              assert_nil answer(query, state: @state.merge("active_task" => "report_problem"))
              assert_nil answer(query, state: @state.merge("active_task" => "registration"))
              assert_nil answer(query, state: @state.merge(AnswerContext::KEY => nil))
              later = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "b" * 64, now: NOW + AnswerContext::TTL + 1)
              assert_nil answer(query, context: later)
            end
            ["Pošalji prijavu gradu", "Da li si poslala prijavu gradu i koliko imam bodova?",
             "Da li si poslala prijavu BR-2026-9999?"].each do |query|
              assert_nil ReportGuidanceStage.submission_follow_up(turn(query))
            end
          end

          # b3c02 — "Ko vidi moju prijavu?" was refused while the report preview
          # two turns later printed the visibility rules. The card now composes
          # those same reviewed lines, so the two can never disagree.
          def test_the_visibility_card_quotes_the_reviewed_form_copy
            result = answer("Ko vidi moju prijavu kada je pošaljem?")

            assert_equal "answered", result.resolution
            assert_equal "report_guidance", result.reply.answer_intent
            assert_includes result.reply.text, I18n.t("decidim.bih.reports.new.visibility.public", locale: "sr")
            assert_includes result.reply.text, I18n.t("decidim.bih.reports.new.visibility.private", locale: "sr")
            assert_equal @state, result.state, "a card writes no conversation state"
          end

          def test_the_visibility_card_answers_the_bare_address_and_photo_follow_up
            result = answer("Pitam baš za adresu i fotografiju, ne za moje ime.")

            assert_includes result.reply.text, "Javno:"
            assert_includes result.reply.text, "Nije javno:"
          end

          # b3c07 — anonymity, and the follow-up that confuses the report's
          # address with the citizen's own.
          def test_anonymity_and_address_are_two_different_answers
            anonymity = answer("Mogu li prijaviti problem anonimno?")
            address = answer("Da li anonimno znači da se ni moja adresa ne vidi?")

            assert_includes anonymity.reply.text, "anonimno prema službi: kontakt se ne prosljeđuje"
            assert_includes anonymity.reply.text, "Ime prijavioca nije javno ni za jednu prijavu"
            assert_includes anonymity.reply.text, "registrovanom nalogu zadržava iste bodove"
            assert_includes anonymity.reply.text, "Bez veze s registrovanim nalogom nema ličnih bodova"
            assert_includes address.reply.text, "Adresa problema je javna"
            assert_includes address.reply.text, "provjera pismom je zaseban postupak s privremenom obradom adrese"
            refute_equal anonymity.reply.text, address.reply.text
          end

          # b3c19 / b3c20 — both dead-ended on "za ovu temu još nemam provjeren
          # izvor".
          def test_photo_and_duplicate_questions_are_answered_from_the_real_feature
            photo = answer("Da li mogu poslati sliku uz prijavu?")
            duplicate = answer("Neko je već prijavio isti problem. Kako da potvrdim da i mene pogađa?")
            notifications = answer("Da li potvrda tuđe prijave znači da ću primati obavještenja?")

            assert_includes photo.reply.text, "5 MB"
            assert_includes duplicate.reply.text, "Isti problem — dodaj potvrdu"
            assert_includes notifications.reply.text, "nije pretplata na obavještenja"
          end

          # b3c21 — the honest position on resolution time. The 48 hours are the
          # city's promise to ANSWER; no repair deadline exists anywhere in the
          # code, so none may be stated.
          def test_the_resolution_time_card_never_promises_a_repair_deadline
            %w(sr sr-Cyrl bs hr en).each do |locale|
              text = ReportGuidance.answer(ReportGuidance::RESOLUTION_TIME, locale:)

              refute_empty text.to_s.strip, "#{locale} resolution-time card"
              refute_match(/popravljen\w*\s+(?:za|u\s+roku)|repaired\s+within|fixed\s+within/i, text)
            end
            sr = answer("Da li Sistem 48 znači da je kvar sigurno popravljen za 48 sati?")

            assert_includes sr.reply.text, "odgovor, ne popravka"
          end

          # b3c22 — "forwarded" is a status an operator sets, not something a
          # report gets by existing.
          def test_forwarding_distinguishes_received_from_sent_to_the_service
            received = answer("Da li moja prijava preko MI automatski dobija status da je poslata gradu?")
            accepted = answer("Kako da znam da je prosljeđivanje zaista prihvaćeno?")

            assert_includes received.reply.text, "Primljeno"
            assert_includes received.reply.text, "Poslato službi"
            assert_equal received.reply.text, accepted.reply.text
          end

          # b3c17 — an anonymous citizen who lost the reference. A SIGNED-IN one
          # must keep the real scoped read instead.
          def test_own_reports_guidance_is_for_anonymous_citizens_only
            anonymous = answer("Nemam oznaku. Gdje se nalaze moje prijave nakon prijave na nalog?")

            assert_includes anonymous.reply.text, "prijave-pronadji"
            assert_equal "status", anonymous.reply.answer_intent

            signed_in = Contracts::TrustedContext.new(organization_id: 1, actor_id: 7, account_state: "registered",
                                                      conversation_key: "b" * 64, now: NOW)

            assert_nil answer("Nemam oznaku. Gdje se nalaze moje prijave nakon prijave na nalog?", context: signed_in)
          end

          def test_an_own_report_list_request_is_left_to_the_scoped_read
            assert_nil answer("Koje su moje prijave?")
            assert_nil answer("status moje posljednje prijave")
          end

          # A civic noise complaint is legitimate; a neighbour dispute is not a
          # communal service request. Neither may be answered as the other.
          def test_scope_routes_a_private_dispute_without_rejecting_civic_noise
            dispute = answer("Komšija mi pravi buku svako veče, mogu li to prijaviti?")

            assert_includes dispute.reply.text, "komunalna policija"
            assert_includes dispute.reply.text, "122"
            assert_includes dispute.reply.text, "buka sa gradilišta"
            assert_nil answer("Buka sa gradilišta svako jutro, mogu li prijaviti?"),
                       "an ordinary civic report is not diverted into a guidance card"
          end

          # The daily cap never blocks the report; the points framing of the cap
          # stays with the goodwill rules.
          def test_the_limits_card_answers_the_report_and_leaves_points_to_goodwill
            limits = answer("Ako danas pošaljem šestu prijavu, hoće li biti odbijena?")

            assert_includes limits.reply.text, "Limit ograničava bodove, ne podnošenje"
            assert_includes limits.reply.text, "dodatna prijava se zavodi i ide na pregled"
            assert_includes limits.reply.text, "Predaja službi je zaseban korak poslije pregleda"
            assert_includes limits.reply.text, "tehnička zaštita"
            assert_nil answer("Ako danas pošaljem šestu prijavu, hoće li biti odbijena zbog bodova?")
          end

          def test_account_journeys_and_report_intake_are_never_taken_by_a_card
            ["Kako da se registrujem?", "Prijava na postojeći nalog", "Zaboravio sam lozinku, kako da uđem na svoj nalog?",
             "Smeće nije odvezeno, hoću prijaviti", "Hoću objaviti poruku komšijama", "Kako da izvadim rodni list",
             "Koliko bodova nosi prijava problema"].each do |text|
              assert_nil answer(text), "#{text.inspect} must not be answered by a report card"
            end
          end

          def test_a_citizen_in_the_middle_of_a_report_keeps_the_turn
            drafting = @state.merge("pending_slot" => "description")

            assert_nil answer("Ko vidi moju prijavu kada je pošaljem?", state: drafting)
            assert_nil answer("Ko vidi moju prijavu kada je pošaljem?", state: @state.merge("draft" => { "id" => "x" }))
          end

          def test_a_cyrillic_question_is_answered_in_cyrillic
            result = answer("Ко види моју пријаву када је пошаљем?")

            assert_match(/\p{Cyrillic}/, result.reply.text)
            refute_match(/\bJavno:/, result.reply.text)
          end

          def test_the_stage_runs_after_emergency_and_the_civic_cards
            names = PreModelStages.stage_names

            assert_operator names.index("report_guidance_card"), :>, names.index("emergency")
            assert_operator names.index("report_guidance_card"), :>, names.index("public_information_card")
            assert_operator names.index("report_guidance_card"), :<, names.index("service_follow_up")
          end

          def test_every_card_has_copy_in_every_locale
            cards = [ReportGuidance::VISIBILITY, ReportGuidance::ADDRESS_PRIVACY, ReportGuidance::ANONYMITY,
                     ReportGuidance::PHOTO, ReportGuidance::DUPLICATE, ReportGuidance::FORWARDING,
                     ReportGuidance::RESOLUTION_TIME, ReportGuidance::OWN, ReportGuidance::PUBLIC_MAP,
                     ReportGuidance::SCOPE, ReportGuidance::LIMITS, ReportGuidance::GUIDANCE_ONLY]
            Contracts::LOCALES.each do |locale|
              cards.each do |card|
                text = ReportGuidance.answer(card, locale:)

                refute_empty text.to_s.strip, "#{locale}:#{card.name}"
                refute_includes text, "translation missing", "#{locale}:#{card.name}"
                refute_includes text, "%{", "#{locale}:#{card.name} left a placeholder unfilled"
              end
            end
          end

          # Re-testing the deployed release found two card-ordering defects.
          # CARD_RULES uses #find, so the order IS the behaviour.
          def test_a_forwarding_question_is_not_answered_by_the_resolution_card
            # It answered "Ne." before - the opposite of this engine's own
            # report_forwarding copy - because RESOLUTION_CUE was tried first.
            card = ReportGuidance.card_for(Decidim::Bih::Text.fold("Da li se moja prijava prosljeđuje u Sistem 48?"))

            assert_equal "report_forwarding", card&.name
          end

          def test_a_duration_question_without_a_report_subject_is_left_alone
            # "koliko traje" also asks how long the verification link lasts,
            # which belongs to the account classifier. Claiming it here meant
            # the citizen was told Sistem 48's 48 hours.
            assert_nil ReportGuidance.card_for(Decidim::Bih::Text.fold("Koliko traje link za potvrdu?"))
            assert_equal "report_resolution_time",
                         ReportGuidance.card_for(Decidim::Bih::Text.fold("Koliko traje dok se prijava riješi?"))&.name
          end

          # R6. The stage used to return the state untouched, so a "kraće"
          # after one of these cards had no subject to land on and was
          # classified from scratch (case r9c02). It now records WHAT IT
          # ANSWERED - and only that.
          def test_the_stage_retains_the_card_it_answered
            result, retained = retention_for("Ko vidi moju prijavu kada je pošaljem?")

            assert_equal "answered", result.resolution
            assert_equal({ kind: "report_card", subject: "report_visibility",
                           anchor: "Ko vidi moju prijavu kada je pošaljem?" }, retained)
          end

          # A card is reviewed copy, not a read about this citizen: the record
          # names the card and keeps the citizen's own question, and carries no
          # action, no topic and no slot of any kind.
          def test_the_retained_record_carries_nothing_about_the_citizens_own_report
            _, retained = retention_for("Da li je moja prijava anonimna?")

            assert_equal [:kind, :subject, :anchor].sort, retained.keys.sort
            assert_nil AnswerContext.capture(kind: "report_card", subject: "report_visibility",
                                             action: "report_problem", topic: "report", anchor: "x y",
                                             now: NOW, state_expires_at: NOW.to_f + Contracts::CONTEXT_TTL)
          end

          # A card that this host has no copy for answers nothing, so there is
          # nothing to retain either.
          def test_a_declined_turn_retains_nothing
            _, retained = retention_for("Koliko traje link za potvrdu?")

            assert_nil retained
          end
        end
      end
    end
  end
end

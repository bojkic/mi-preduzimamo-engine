# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/civic_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Selection for the personal, points, race and donation questions —
        # WHICH read a citizen's words select, before the model is asked. The
        # answers themselves are proved in responder_goodwill_test.rb.
        #
        # Every prompt below is quoted from the 14.09.2026 rated corpus
        # (docs/audits/2026-09-14-milica-conversation-review) unless marked as
        # a held-out paraphrase.
        class PersonalReadRoutesTest < Minitest::Test
          # The eleven balance phrasings measured against a genuinely
          # authenticated session on 14.09.2026. All eleven returned the same
          # 1.422-character reward catalogue while the account held 245 points.
          BALANCE_PROMPTS = [
            "Koliko imam bodova?",
            "koliko bodova imam",
            "moji bodovi",
            "moje stanje bodova",
            "stanje mojih bodova",
            "koliko sam skupio bodova",
            "koliko sam sakupila bodova",
            "Koliko bodova imam na svom nalogu?",
            "Koji je moj rang?",
            "koji mi je nivo",
            "Prikaži mi moje bodove"
          ].freeze

          def route_for(text)
            query = Decidim::Bih::Text.fold(text)
            DeterministicRoutes.routes.find { |route| route.matcher.call(query, text) }&.name
          end

          def read_for(text) = CivicQuestion.classify(text)

          def test_every_measured_balance_phrasing_selects_the_balance_route
            BALANCE_PROMPTS.each do |prompt|
              assert_equal "goodwill_balance", route_for(prompt), prompt
              read = read_for(prompt)
              assert_equal "goodwill", read.fetch(:topic), prompt
              assert_equal "balance", read.dig(:entities, "category"), prompt
            end
          end

          def test_the_balance_route_reads_a_corrective_last_clause
            # b4c01 turn 2, after turn 1 was answered with the catalogue.
            assert_equal "goodwill_balance", route_for("Ne pitam za nagrade. Koliko bodova imam na svom nalogu?")
          end

          def test_the_balance_route_answers_cyrillic_and_english_spellings
            assert_equal "goodwill_balance", route_for("Колико имам бодова?")
            assert_equal "goodwill_balance", route_for("How many points do I have?")
          end

          # The schedule and the ledger are different questions, and `earning`
          # is registered first precisely so this stays true.
          def test_the_earning_route_still_wins_for_schedule_questions
            ["Kako da zaradim bodove", "kako se skupljaju bodovi", "Koliko bodova nosi prijava problema",
             "Koliko bodova dobijem za uspješan poziv komšiji?"].each do |prompt|
              assert_equal "earning", route_for(prompt), prompt
            end
          end

          def test_the_own_state_and_launch_routes_keep_their_utterances
            assert_equal "invitation", route_for("Imam li pozivnicu?")
            assert_equal "komsiluk", route_for("Koji je moj komšiluk?")
            assert_equal "invitation", route_for("moj broj rezervacije")
            # The 20 points are a threshold, never a price: that is launch policy.
            assert_equal "launch_topic", route_for("Da li se za pozivnicu za lansiranje oduzima 20 bodova?")
          end

          def test_a_pending_referral_is_its_own_question_not_the_balance
            ["Komšija se registrovao preko mog linka prije sat vremena. Zašto nema bodova za poziv?",
             "zašto nema bodova za poziv komšiji",
             "kad stižu bodovi za poziv komšije"].each do |prompt|
              assert_equal "goodwill_referral", route_for(prompt), prompt
              assert_equal "referral_pending", read_for(prompt).dig(:entities, "category"), prompt
            end
          end

          def test_a_daily_cap_question_is_not_the_rewards_catalogue
            ["Ako danas napravim šestu prijavu problema, da li će biti odbijena zbog bodova?",
             "Znači dnevna granica utiče samo na bodove, ne na prijavu?",
             "postoji li dnevni limit za bodove"].each do |prompt|
              assert_equal "goodwill_daily_cap", route_for(prompt), prompt
              assert_equal "cap", read_for(prompt).dig(:entities, "category"), prompt
            end
          end

          def test_a_price_question_selects_the_rewards_catalogue_deliberately
            ["Koliko bodova košta MI majica?", "Koje su dvije najjeftinije dostupne nagrade?",
             "koliko košta platnena torba"].each do |prompt|
              assert_equal "reward_price", route_for(prompt), prompt
              assert_equal "rewards", read_for(prompt).fetch(:topic), prompt
            end
          end

          def test_the_standings_route_takes_the_live_half_of_the_race
            ["Ko trenutno vodi?", "ko vodi u trci", "koji komšiluk vodi",
             "Gdje mogu pogledati trenutni poredak Trke komšiluka?"].each do |prompt|
              assert_equal "race_standings", route_for(prompt), prompt
              read = read_for(prompt)
              assert_equal "launch", read.fetch(:topic), prompt
              assert_equal "race_standings", read.dig(:entities, "category"), prompt
            end
          end

          # "Ko vodi X" is a question about who RUNS X unless the race is named.
          # Both of these were asked in the rated corpus.
          def test_who_runs_the_platform_is_never_the_race_leaderboard
            ["ko vodi ovu platformu", "Ko vodi platformu MI PRE(D)UZIMAMO?",
             "ko vodi Lokalnu fondaciju Bijeljina"].each do |prompt|
              assert_nil route_for(prompt), prompt
            end
          end

          def test_the_standings_route_is_evaluated_before_the_launch_topic_pin
            names = DeterministicRoutes.route_names
            assert_operator names.index("race_standings"), :<, names.index("launch_topic")
          end

          def test_a_giving_question_and_an_allocation_question_are_different_reads
            ["Kako da doniram?", "Daj mi broj računa ili link gdje mogu uplatiti donaciju."].each do |prompt|
              assert_equal "donation_giving", route_for(prompt), prompt
              assert_equal "organizacija", read_for(prompt).dig(:entities, "category"), prompt
            end
            ["Mogu li prvo vidjeti projekte pa odabrati kome doniram?",
             "Gdje mogu vidjeti kako se troše donacije i ko odlučuje o projektima?",
             "Ne pitam koliko je novca prikupljeno, nego kome je dodijeljen."].each do |prompt|
              assert_equal "donation_allocation", route_for(prompt), prompt
              assert_equal "projekti", read_for(prompt).dig(:entities, "category"), prompt
            end
          end

          # A refusal is not a giving question, and answering it with the
          # foundation's account number is worse than answering nothing.
          def test_a_refusal_to_pay_is_never_a_giving_question
            ["Ne želim da doniram, hoću da prijavim problem.",
             "Neću sada plaćati. Samo mi reci gdje da pročitam uslove.",
             "nemoj mi slati broj računa"].each do |prompt|
              refute_equal "donation_giving", route_for(prompt), prompt
            end
          end

          def test_unrelated_civic_questions_are_left_to_the_existing_routes
            ["Kada se odvozi smeće u Dvorovima?", "Gdje je službeni glasnik?",
             "Prijavljujem rupu na putu", "hvala ti puno", "Ko ste vi?",
             "Ko finansira platformu MI PRE(D)UZIMAMO?"].each do |prompt|
              refute_includes %w(goodwill_balance goodwill_referral goodwill_daily_cap race_standings reward_price
                                 donation_giving donation_allocation),
                              route_for(prompt), prompt
            end
          end

          # --- R4: affordability, and what it must never claim ---------------

          def test_an_affordability_question_selects_the_comparison_not_either_half
            ["Da li imam dovoljno bodova za majicu?", "Imam li dovoljno bodova za torbu?",
             "Da li imam dosta bodova za termos?", "Koliko mi bodova fali za majicu?",
             "Mogu li priuštiti majicu?"].each do |prompt|
              assert_equal "reward_affordability", route_for(prompt), prompt
            end
          end

          # THE INVARIANT: the launch invitation's 20 points are a THRESHOLD and
          # are never deducted, so "do I have enough for the pozivnica" belongs
          # to the launch policy and must never be answered as a purchase.
          # +launch_topic+ is registered before +reward_affordability+ and this
          # is what holds that order to its meaning.
          def test_the_launch_invitation_is_never_answered_as_something_points_buy
            ["Da li imam dovoljno bodova za pozivnicu?", "Koliko bodova košta pozivnica?",
             "Da li se za pozivnicu za lansiranje oduzima 20 bodova?"].each do |prompt|
              refute_equal "reward_affordability", route_for(prompt), prompt
              assert_equal "launch", read_for(prompt).fetch(:topic), prompt
            end
          end

          # A plain price question and a plain balance question each keep their
          # own route: affordability sits between them and claims neither.
          def test_affordability_claims_neither_the_price_nor_the_balance_question
            assert_equal "reward_price", route_for("Koliko bodova košta majica?")
            assert_equal "goodwill_balance", route_for("Koliko imam bodova?")
            assert_equal "reward_price", route_for("Koje su dvije najjeftinije nagrade?")
          end

          # --- R8: the four questions the account menu used to swallow -------

          def test_each_of_the_four_account_questions_selects_its_own_route
            { "Da li sam verifikovan?" => "own_state_verification",
              "Da li mi je broj telefona potvrđen?" => "own_state_verification",
              "Koliko sam ljudi pozvao?" => "own_state_referrals",
              "Kako se zovem?" => "own_state_identity",
              "Gdje je moj link za pozivanje komšija?" => "own_state_invite_link" }.each do |prompt, route|
              assert_equal route, route_for(prompt), prompt
            end
          end

          # The built-in prefix is frozen order, and the new routes sit after
          # every one of it — so nothing the built-ins answer today moves.
          def test_the_new_own_state_routes_sit_after_every_built_in
            names = DeterministicRoutes.route_names

            assert_equal %w(document board earning pharmacy invitation komsiluk mz_contact), names.first(7)
            assert_operator names.index("own_state_verification"), :>, names.index("mz_contact")
            assert_operator names.index("reward_affordability"), :<, names.index("goodwill_balance")
            assert_operator names.index("reward_affordability"), :<, names.index("reward_price")
            assert_operator names.index("launch_topic"), :<, names.index("reward_affordability")
          end

          # CivicQuestion refuses anything over 160 characters, and a trailing
          # clause is bounded tighter still: a long tail is prose, not a question.
          def test_long_prose_never_selects_a_personal_read
            assert_nil read_for("#{"a" * 150} moji bodovi")
            tail = "#{"b" * 130} koliko imam bodova"
            assert_nil PersonalReadRoutes.clause("Nešto sasvim drugo. #{tail}")
          end
        end
      end
    end
  end
end

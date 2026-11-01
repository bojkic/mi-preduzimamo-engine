# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "i18n"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/time"
require_relative "../../../../../app/services/decidim/bih/concierge/responder"
require_relative "../../../../../app/services/decidim/bih/race/visibility"

module Decidim
  module Bih
    module Concierge
      # The personal, points, cap, referral and race answers, through the REAL
      # Responder#respond chain the secondary read adapter uses — no classifier,
      # keyword order, no model. The record lookups are stubbed; the COPY is the
      # engine's own, loaded from config/locales, so a missing or renamed key
      # fails here rather than in production.
      #
      # What this file exists to prove, beyond "the route matched":
      #   * Responder#goodwill_reply is the handler that RUNS and answers
      #     (#executed records it), so the balance is end-to-end reachable and
      #     not merely allow-listed;
      #   * a read creates no ledger account, no award and no redemption;
      #   * an anonymous, foreign-tenant or actor-mismatched conversation is
      #     given sign-in guidance and no numbers at all.
      class ResponderGoodwillTest < Minitest::Test
        def run
          Decidim::Bih::Race::Visibility.stub(:visible?, ->(_org) { @race_visible != false }) { super }
        end

        LOCALES = %w(sr sr-Cyrl bs hr en).freeze
        LOCALE_FILES = %w(sr.yml sr-Cyrl.yml bs.yml hr.yml en.yml decidim_bih_dialogue.yml).freeze

        Message = Struct.new(:text, :user, :trusted_context, keyword_init: true) do
          def image_url = nil

          def latitude = nil

          def longitude = nil
        end
        Scope = Struct.new(:actor_id, :organization_id, keyword_init: true)
        User = Struct.new(:id, :decidim_organization_id, keyword_init: true)
        Organization = Struct.new(:id)
        Level = Struct.new(:key, :points_to_next, keyword_init: true)
        Account = Struct.new(:balance, :contribution_score, :level, keyword_init: true)
        # Stands in for a Decidim::Bih::Goodwill::Reward row: the two fields
        # the affordability answer reads, and nothing else.
        CatalogReward = Struct.new(:name, :cost, keyword_init: true)
        # The live catalogue on 14.09.2026, in cost order.
        CATALOGUE = [
          CatalogReward.new(name: "MI! naljepnice", cost: 150),
          CatalogReward.new(name: "Digitalna zahvalnica", cost: 200),
          CatalogReward.new(name: "Platnena torba", cost: 300),
          CatalogReward.new(name: "MI! majica", cost: 500),
          CatalogReward.new(name: "Kupon partnera", cost: 600),
          CatalogReward.new(name: "Termos boca", cost: 800)
        ].freeze
        Leader = Struct.new(:display_name, :score, keyword_init: true)

        # The eleven balance phrasings measured against a genuinely
        # authenticated session on 14.09.2026; every one returned the same
        # 1.422-character reward catalogue while the account held 245 points.
        BALANCE_PROMPTS = [
          "Koliko imam bodova?", "koliko bodova imam", "moji bodovi", "moje stanje bodova",
          "stanje mojih bodova", "koliko sam skupio bodova", "koliko sam sakupila bodova",
          "Koliko bodova imam na svom nalogu?", "Koji je moj rang?", "koji mi je nivo",
          "Prikaži mi moje bodove"
        ].freeze

        # Stands in for Decidim::Bih::Goodwill::EarningRules: the three
        # read-only methods the goodwill answers consult.
        class FakeRules
          attr_reader :schedule

          def initialize(schedule, caps)
            @schedule = schedule
            @caps = caps
          end

          def points_for(action) = @schedule[action.to_sym].to_i

          def cap_for(action) = @caps[action.to_sym]

          def cap_period_for(action) = action.to_sym == :proposal ? :month : :day
        end

        # Answers exactly the three read-only messages Responder sends it.
        class FakeStandings
          attr_reader :calls

          def initialize(leaders: {}, computed_at: Time.utc(2026, 9, 14, 8, 30), final: false, raises: false)
            @leaders = leaders
            @computed_at = computed_at
            @final = final
            @raises = raises
            @calls = []
          end

          def leader(zone)
            raise "standings unavailable" if @raises

            @calls << [:leader, zone]
            @leaders[zone]
          end

          def computed_at
            @calls << [:computed_at]
            @computed_at
          end

          def final?
            @calls << [:final?]
            @final
          end
        end

        # Records the handler that ANSWERED, so "the goodwill handler produced
        # this reply" is an observation rather than an inference from the text.
        module HandlerProbe
          [:goodwill_reply, :race_standings_reply, :launch_reply].each do |handler|
            define_method(handler) do |message|
              reply = super(message)
              executed << handler if reply
              reply
            end
          end
        end

        class ProbedResponder < Responder
          prepend HandlerProbe

          attr_accessor :account, :standings, :rank, :catalogue
          attr_reader :executed, :log, :account_lookups, :catalogue_reads

          def initialize(organization_id: 7, standings: nil, rules: nil)
            @organization = Organization.new(organization_id)
            @goodwill_user_resolver = ->(message) { message.user }
            @standings = standings
            @goodwill_rules = rules
            @rank = 3
            @executed = []
            @log = []
            @account_lookups = []
            @catalogue_reads = 0
            @catalogue = CATALOGUE
            @classifier = nil
          end

          private

          # The reward catalogue, without a database. Counted so the test can
          # assert that answering affordability reads it, and that a question
          # naming no reward does not.
          def redeemable_rewards
            @catalogue_reads += 1
            catalogue
          end

          def rewards_url = "/hub?tab=nagrade"

          # The read-only lookup, without a database. It records every lookup so
          # the test can assert the balance path reads once and reads nothing else.
          def goodwill_account_for(user)
            @account_lookups << user.id
            return nil unless user.decidim_organization_id == organization.id

            account
          end

          def goodwill_rank_for(_account) = rank

          # The real handler's first line is
          #   return nil unless Decidim::Bih.donations_provider_available_for?(donations, organization:)
          # and this brain is built with no donations provider, so nil IS its
          # real behaviour. It is reproduced here only because that predicate
          # lives in lib/decidim/bih.rb, which a host-free unit test never loads.
          def donation_reply(_message) = nil

          def race_standings = standings

          def race_url = "/hub?tab=trka"

          def contribution_url = "/hub/moj-doprinos"

          def sign_in_url = "/users/sign_in"

          def rules_url = "/hub?tab=kako"

          def log_failure(code, _error = nil)
            log << code
          end
        end

        def setup
          @previous = { backend: I18n.backend, load_path: I18n.load_path, available: I18n.available_locales,
                        enforce: I18n.enforce_available_locales }
          I18n.enforce_available_locales = false
          I18n.backend = I18n::Backend::Simple.new
          I18n.available_locales = LOCALES
          I18n.load_path = LOCALE_FILES.map { |name| File.expand_path("../../../../../config/locales/#{name}", __dir__) }
          I18n.backend.send(:init_translations)
          @responder = ProbedResponder.new(
            rules: FakeRules.new({ volunteer_hour: 100, proposal: 25, referral: 25, report: 20,
                                   komsiluk_selected: 10, verification: 10, comment: 3 },
                                 { report: 5, proposal: 1, comment: 5 })
          )
          @user = User.new(id: 1, decidim_organization_id: 7)
          @responder.account = Account.new(balance: 245, contribution_score: 245, level: Level.new(key: "predvodnik", points_to_next: 55))
        end

        def teardown
          I18n.backend = @previous.fetch(:backend)
          I18n.load_path = @previous.fetch(:load_path)
          I18n.available_locales = @previous.fetch(:available)
          I18n.enforce_available_locales = @previous.fetch(:enforce)
        end

        def ask(text, user: @user, scope: nil)
          @responder.respond(Message.new(text:, user:, trusted_context: scope))
        end

        def t(key, **values)
          I18n.t("decidim.bih.concierge.#{key}", locale: "sr", **values)
        end

        def dialogue_t(key, **values)
          I18n.t("decidim.bih.dialogue.#{key}", locale: "sr", **values)
        end

        # --- the balance actually reaches the existing handler ---------------

        def test_the_measured_balance_phrasings_all_run_the_goodwill_handler
          BALANCE_PROMPTS.each do |prompt|
            @responder.executed.clear
            reply = ask(prompt)

            assert_includes @responder.executed, :goodwill_reply, prompt
            assert_equal "goodwill", reply.answer_intent, prompt
            assert_includes reply.text, "245", prompt
            refute_match(/naljepnic|nagrad/i, reply.text, "#{prompt}: answered with the rewards catalogue")
          end
        end

        def test_the_balance_answer_is_the_engines_own_found_copy
          level = I18n.t("decidim.bih.goodwill.levels.predvodnik", locale: "sr")
          expected = t("goodwill.found", balance: 245, level:, rank: 3, to_next: 55, url: "/hub/moj-doprinos")

          assert_equal expected, ask("Koliko imam bodova?").text
        end

        def test_a_zero_balance_is_a_genuine_zero_not_a_missing_account
          @responder.account = Account.new(balance: 0, contribution_score: 0, level: Level.new(key: "komsija", points_to_next: 10))

          assert_equal t("goodwill.none", url: "/hub/moj-doprinos"), ask("moji bodovi").text
        end

        def test_a_missing_account_never_reports_a_number
          @responder.account = nil
          reply = ask("moji bodovi")

          assert_equal t("goodwill.none", url: "/hub/moj-doprinos"), reply.text
          refute_includes reply.text, "245"
        end

        # --- identity, tenant and actor scope --------------------------------

        def test_an_anonymous_chat_gets_sign_in_guidance_not_a_zero_and_not_a_catalogue
          reply = ask("Koliko imam bodova?", user: nil)

          assert_includes reply.text, t("goodwill.not_linked", url: "/hub/moj-doprinos")
          assert_includes reply.text, dialogue_t("handoff_sign_in", url: "/users/sign_in")
          refute_includes reply.text, "245"
          refute_match(/naljepnic|nagrad/i, reply.text)
        end

        def test_a_user_from_another_organization_is_told_nothing
          reply = ask("moji bodovi", user: User.new(id: 1, decidim_organization_id: 9))

          refute_includes reply.text, "245"
          assert_includes reply.text, dialogue_t("handoff_sign_in", url: "/users/sign_in")
        end

        def test_a_conversation_scoped_to_another_actor_is_refused_without_numbers
          reply = ask("koliko imam bodova", scope: Scope.new(actor_id: 2, organization_id: 7))

          refute_includes reply.text, "245"
          assert_includes @responder.log, "own_state_actor_scope_mismatch"
          assert_includes reply.text, dialogue_t("handoff_sign_in", url: "/users/sign_in")
        end

        def test_a_conversation_scoped_to_another_organization_is_refused_without_numbers
          reply = ask("moji bodovi", scope: Scope.new(actor_id: 1, organization_id: 8))

          refute_includes reply.text, "245"
          assert_includes reply.text, dialogue_t("handoff_sign_in", url: "/users/sign_in")
        end

        # The read-only lookup is consulted once for the signed-in citizen and
        # never for an anonymous one. (That the lookup itself creates no ledger
        # account is proved against the real database by the host test
        # test/services/decidim_app/bijeljina/milica/goodwill_earning_reply_test.rb.)
        def test_a_balance_read_touches_the_account_once_and_never_when_anonymous
          ask("Koliko imam bodova?")
          assert_equal [@user.id], @responder.account_lookups

          ask("moji bodovi", user: nil)
          assert_equal [@user.id], @responder.account_lookups
        end

        # --- the four rule questions, which are not the balance ---------------

        def test_a_daily_cap_question_states_that_the_action_still_goes_through
          reply = ask("Ako danas napravim šestu prijavu problema, da li će biti odbijena zbog bodova?")

          assert_equal "goodwill", reply.answer_intent
          assert_includes reply.text, "nikada za samu radnju"
          refute_match(/naljepnic/i, reply.text)
        end

        def test_a_cap_question_from_an_anonymous_chat_is_answered_without_identity
          reply = ask("Znači dnevna granica utiče samo na bodove, ne na prijavu?", user: nil)

          assert_includes reply.text, "nikada za samu radnju"
          refute_includes reply.text, dialogue_t("handoff_sign_in", url: "/users/sign_in")
        end

        def test_a_referral_question_states_value_delay_gate_and_monthly_limit
          reply = ask("Koliko bodova dobijem za uspješan poziv komšiji?")

          assert_includes reply.text, "24 sata"
          assert_includes reply.text, "10"
          assert_includes reply.text, "potvrđen telefon i izabran komšiluk"
        end

        def test_a_pending_referral_never_claims_to_have_read_the_other_account
          reply = ask("Komšija se registrovao preko mog linka prije sat vremena. Zašto nema bodova za poziv?")

          assert_includes reply.text, "Tuđe privatne podatke ne mogu pogledati"
          assert_includes reply.text, "24 sata"
        end

        def test_a_named_earning_action_is_answered_instead_of_a_top_five_ranking
          reply = ask("koliko bodova nosi prijava problema")

          assert_includes reply.text, I18n.t("decidim.bih.goodwill.actions.report", locale: "sr")
          refute_includes reply.text, I18n.t("decidim.bih.goodwill.actions.volunteer_hour", locale: "sr")
        end

        def test_the_whole_schedule_is_still_the_answer_to_an_open_question
          reply = ask("Kako da zaradim bodove")

          assert_includes reply.text, I18n.t("decidim.bih.goodwill.actions.volunteer_hour", locale: "sr")
          assert_includes reply.text, t("goodwill.earning.note")
        end

        # --- the race leaderboard ---------------------------------------------

        def test_hidden_race_quotes_no_cached_scores
          @responder.standings = FakeStandings.new(leaders: { "grad" => Leader.new(display_name: "Račanska", score: 128) })
          @race_visible = false
          reply = ask("Ko trenutno vodi?")
          refute_includes reply.text, "128"
          assert_empty @responder.standings.calls
        end

        def test_the_standings_answer_separates_grad_and_selo_and_carries_a_timestamp
          @responder.standings = FakeStandings.new(
            leaders: { "grad" => Leader.new(display_name: "Račanska", score: 128),
                       "selo" => Leader.new(display_name: "Velika Obarska", score: 44) }
          )
          reply = ask("Ko trenutno vodi?")

          assert_includes @responder.executed, :race_standings_reply
          assert_equal "launch", reply.answer_intent
          assert_includes reply.text, dialogue_t("race_standings_leader", zone: dialogue_t("race_standings_zone_grad"), name: "Račanska", score: 128)
          assert_includes reply.text, dialogue_t("race_standings_leader", zone: dialogue_t("race_standings_zone_selo"), name: "Velika Obarska", score: 44)
          assert_includes reply.text, "14.09.2026. 10:30"
          assert_includes reply.text, "/hub?tab=trka"
          refute_includes reply.text, "tab=tabla"
        end

        def test_an_empty_zone_says_so_rather_than_borrowing_the_other_leader
          @responder.standings = FakeStandings.new(leaders: { "grad" => Leader.new(display_name: "Račanska", score: 128) })
          reply = ask("ko vodi u trci")

          assert_includes reply.text, dialogue_t("race_standings_no_leader", zone: dialogue_t("race_standings_zone_selo"))
          refute_includes reply.text, "Velika Obarska"
        end

        def test_a_frozen_table_is_labelled_final_and_never_timestamped_as_live
          @responder.standings = FakeStandings.new(leaders: { "grad" => Leader.new(display_name: "Račanska", score: 128) }, final: true)
          reply = ask("Ko trenutno vodi?")

          assert_includes reply.text, dialogue_t("race_standings_final", url: "/hub?tab=trka")
          refute_includes reply.text, "14.09.2026"
        end

        def test_an_unreadable_table_is_explicit_and_quotes_no_number
          @responder.standings = FakeStandings.new(raises: true)
          reply = ask("Ko trenutno vodi?")

          assert_equal dialogue_t("race_standings_unavailable", url: "/hub?tab=trka"), reply.text
          assert_includes @responder.log, "race_standings_unavailable"
        end

        def test_an_unknown_computation_time_is_never_presented_as_current
          @responder.standings = FakeStandings.new(leaders: {}, computed_at: nil)
          reply = ask("Ko trenutno vodi?")

          assert_includes reply.text, dialogue_t("race_standings_unknown_time", url: "/hub?tab=trka")
        end

        # The race and the points economy are separate subjects, and the
        # foundation's payment instructions belong to neither of them: asking
        # what the race is once returned two bank accounts and an IBAN.
        def test_a_race_or_points_answer_carries_no_payment_details
          @responder.standings = FakeStandings.new(leaders: { "grad" => Leader.new(display_name: "Račanska", score: 128) })
          ["Ko trenutno vodi?", "Koliko imam bodova?", "Ako danas napravim šestu prijavu, da li će biti odbijena zbog bodova?"].each do |prompt|
            reply = ask(prompt)

            refute_match(/IBAN|\bra[cč]un\b|\d{3}-\d{6,}/i, reply.text, prompt)
          end
        end

        # --- script ------------------------------------------------------------

        def test_a_cyrillic_balance_question_is_answered_in_cyrillic
          reply = ask("Колико имам бодова?")

          assert_match(/\p{Cyrillic}/, reply.text)
          assert_includes reply.text, "245"
        end

        # --- "what ARE the points" ---------------------------------------------
        #
        # Measured on production on 14.09.2026: "Šta su bodovi zajedništva?"
        # followed by "Ne tražim nagrade, nego objašnjenje bodova." returned
        # the rewards catalogue in 5 of 9 sends and the partner-organisation
        # directory — donation account and IBAN included — in the other 4.
        # The points economy is walled off from money; a definition question
        # is answered from the effective schedule and from nothing else.
        EXPLANATION_PROMPTS = [
          "Šta su bodovi zajedništva?", "Ne tražim nagrade, nego objašnjenje bodova.",
          "Čemu služe bodovi?", "Objasni mi bodove.", "Kako funkcionišu bodovi zajedništva?",
          "Šta znače ovi bodovi?", "Koja je svrha bodova?"
        ].freeze

        def test_a_points_explanation_question_runs_the_goodwill_handler_and_answers_from_the_schedule
          EXPLANATION_PROMPTS.each do |prompt|
            @responder.executed.clear
            reply = ask(prompt)

            assert_includes @responder.executed, :goodwill_reply, prompt
            assert_equal "goodwill", reply.answer_intent, prompt
            assert_includes reply.text, t("goodwill.earning.intro"), prompt
            assert_includes reply.text, t("goodwill.earning.note"), prompt
          end
        end

        # The defect in one assertion: a donation account arriving as the
        # answer to "explain the points to me" says points can be bought.
        def test_a_points_explanation_never_carries_payment_details_a_price_or_a_balance
          EXPLANATION_PROMPTS.each do |prompt|
            reply = ask(prompt)

            refute_match(/IBAN|\bra[cč]un\b|\d{3}-\d{6,}/i, reply.text, prompt)
            refute_match(/naljepnic|cijena u bodovima/i, reply.text, prompt)
            refute_includes reply.text, "245", prompt
          end
        end

        # An explanation reads no ledger: it is the same answer for every
        # citizen, including one nobody has signed in.
        def test_a_points_explanation_reads_no_account_and_works_for_an_anonymous_citizen
          reply = ask("Šta su bodovi zajedništva?", user: nil)

          assert_includes reply.text, t("goodwill.earning.intro")
          assert_empty @responder.account_lookups
        end

        # --- R4: affordability is the COMPARISON, not either half ----------
        #
        # "Da li imam dovoljno bodova za majicu?" measured on 14.09.2026:
        # anonymous and signed in, in a fresh session, it returned the three
        # cheapest rewards with their prices and the majica not among them;
        # one turn after a balance question it returned the balance reply byte
        # for byte. Both numbers exist on the platform; nothing put them in one
        # sentence.

        def test_affordability_compares_the_balance_against_the_reward_cost
          @responder.account = Account.new(balance: 360, contribution_score: 360, level: Level.new(key: "predvodnik", points_to_next: 240))
          reply = ask("Da li imam dovoljno bodova za majicu?")

          assert_includes @responder.executed, :goodwill_reply
          assert_includes reply.text, "MI! majica"
          assert_includes reply.text, "500 bodova", "the price comes from the catalogue"
          assert_includes reply.text, "360 bodova", "the balance comes from the ledger"
          assert_includes reply.text, "140 bodova", "and the answer is the difference"
          assert_equal 1, @responder.account_lookups.length, "the balance is read once, through the authorized port"
        end

        def test_affordability_says_yes_when_the_balance_covers_the_cost
          @responder.account = Account.new(balance: 620, contribution_score: 620, level: Level.new(key: "predvodnik", points_to_next: 0))
          reply = ask("Imam li dovoljno bodova za majicu?")

          assert_includes reply.text, "dovoljno je"
          assert_includes reply.text, "500 bodova"
          assert_includes reply.text, "620 bodova"
          refute_includes reply.text, "fali", "nothing is missing when the balance covers the cost"
        end

        # The accusative is not the nominative. The host catalogue reader
        # matches whole folded words, which is why "za majicu" never found
        # "MI! majica" at all.
        def test_a_reward_named_in_any_case_is_still_the_reward_that_was_named
          @responder.account = Account.new(balance: 360, contribution_score: 360, level: Level.new(key: "predvodnik", points_to_next: 240))
          ["Da li imam dovoljno bodova za majicu?", "Imam li dovoljno bodova za majicu",
           "Da li imam dosta bodova za MI! majicu?"].each do |prompt|
            assert_includes ask(prompt).text, "500 bodova", prompt
          end
        end

        def test_a_zero_balance_is_a_real_answer_and_not_a_refusal
          @responder.account = nil
          reply = ask("Da li imam dovoljno bodova za majicu?")

          assert_includes reply.text, "0 bodova"
          assert_includes reply.text, "500 bodova"
        end

        # An anonymous chat gets the hand-off and NO number about them. The
        # question is about their balance, and there is no balance to read.
        def test_an_anonymous_affordability_question_gets_the_sign_in_hand_off
          reply = ask("Da li imam dovoljno bodova za majicu?", user: nil)

          assert_includes reply.text, t("goodwill.not_linked", url: "/hub/moj-doprinos")
          assert_empty @responder.account_lookups
          refute_includes reply.text, "500", "an anonymous chat is handed off, not answered with a comparison"
        end

        def test_a_scope_mismatch_is_handed_off_rather_than_compared
          @responder.account = Account.new(balance: 360, contribution_score: 360, level: Level.new(key: "predvodnik", points_to_next: 240))
          reply = ask("Da li imam dovoljno bodova za majicu?", scope: Scope.new(actor_id: 99, organization_id: 7))

          assert_includes reply.text, t("goodwill.not_linked", url: "/hub/moj-doprinos")
          assert_includes @responder.log, "own_state_actor_scope_mismatch"
        end

        # A question naming no reward we stock, or naming two, is NOT answered
        # with a comparison: handing a citizen a price they did not ask about
        # is worse than handing them the catalogue.
        def test_a_question_naming_no_stocked_reward_declines_to_compare
          @responder.account = Account.new(balance: 360, contribution_score: 360, level: Level.new(key: "predvodnik", points_to_next: 240))

          assert_nil @responder.send(:goodwill_affordability_reply, Message.new(text: "Da li imam dovoljno bodova za bicikl?", user: @user),
                                     "Da li imam dovoljno bodova za bicikl?", "da li imam dovoljno bodova za bicikl")
        end

        def test_a_question_naming_two_rewards_declines_to_compare
          @responder.account = Account.new(balance: 360, contribution_score: 360, level: Level.new(key: "predvodnik", points_to_next: 240))
          text = "Da li imam dovoljno bodova za majicu ili torbu?"

          assert_nil @responder.send(:goodwill_affordability_reply, Message.new(text:, user: @user), text, Decidim::Bih::Text.fold(text))
        end

        # An unreadable catalogue answers nothing here rather than a guessed
        # price, and the turn falls through to the catalogue reader.
        def test_an_unreadable_catalogue_declines_rather_than_guessing_a_price
          @responder.catalogue = []
          text = "Da li imam dovoljno bodova za majicu?"

          assert_nil @responder.send(:goodwill_affordability_reply, Message.new(text:, user: @user), text, Decidim::Bih::Text.fold(text))
        end

        # The wall between recognition and power holds in the new answer too:
        # no payment details, and no suggestion that points buy influence.
        def test_an_affordability_answer_carries_no_payment_details
          @responder.account = Account.new(balance: 360, contribution_score: 360, level: Level.new(key: "predvodnik", points_to_next: 240))
          reply = ask("Da li imam dovoljno bodova za majicu?")

          refute_match(/IBAN|\d{3}-\d{6,}/i, reply.text)
          refute_match(/glasanj|glas\b/i, reply.text)
        end

        # A plain price question keeps its own route: affordability must not
        # swallow the catalogue.
        def test_a_plain_price_question_is_not_claimed_by_affordability
          text = "Koliko bodova košta majica?"

          assert_nil @responder.send(:goodwill_affordability_reply, Message.new(text:, user: @user), text, Decidim::Bih::Text.fold(text))
          assert_equal 0, @responder.catalogue_reads, "a price question never reaches the affordability catalogue read"
        end

        def test_a_balance_question_is_not_claimed_by_affordability
          @responder.account = Account.new(balance: 360, contribution_score: 360, level: Level.new(key: "predvodnik", points_to_next: 240))
          reply = ask("Koliko imam bodova?")

          refute_includes reply.text, "500 bodova"
          assert_equal 0, @responder.catalogue_reads
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "digest"
require "i18n"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/time"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/civic_question"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/understand"
require_relative "../../../../../../app/services/decidim/bih/concierge/responder"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # "Šta su bodovi zajedništva?" — WHICH read the question selects, and
        # what the citizen is actually told.
        #
        # Measured on production on 14.09.2026 with the throttled web-chat
        # client. The two-turn sequence below returned the 401-character
        # rewards catalogue in 5 of 9 sends and, in the other 4, a
        # 1.298-character partner-organisation directory carrying the
        # foundation's published donation account 555-00000652046-79 and
        # IBAN BA395550000065058015.
        #
        # The account number is not a leak — it is legitimately on the
        # foundation's own public organisation profile, and a genuine partner
        # question must keep reaching it (proved below). The defect is the
        # routing: goodwill points are walled off from money and from the
        # binding vote, and answering "explain the points to me" with a
        # donation account tells the citizen they can be bought.
        class PointsExplainerRouteTest < Minitest::Test
          # The exact two turns measured on production.
          REPRODUCER = ["Šta su bodovi zajedništva?", "Ne tražim nagrade, nego objašnjenje bodova."].freeze

          EXPLANATION_PROMPTS = [
            # definition
            "Šta su bodovi zajedništva?", "Šta su bodovi?", "šta su to bodovi zajedništva",
            "Šta je bod zajedništva?", "Šta znače ovi bodovi?", "Шта су бодови заједништва?",
            "What are community points?",
            # purpose
            "Čemu služe bodovi?", "Zašto postoje bodovi zajedništva?", "Koja je svrha bodova?",
            # explicit request to be told
            "Ne tražim nagrade, nego objašnjenje bodova.", "Objasni mi bodove.",
            "objasni mi sistem bodova", "pojasni mi bodove zajedništva",
            "Reci mi nešto o bodovima.", "Pričaj mi o bodovima zajedništva.",
            "Možeš li detaljnije o bodovima?", "explain the points",
            # mechanics
            "Kako funkcionišu bodovi zajedništva?", "kako radi sistem bodova",
            "Objasni mi, molim te, kako rade bodovi.", "how do points work"
          ].freeze

          # What points BUY is the catalogue's question, not this route's.
          EXCHANGE_PROMPTS = [
            "Šta mogu dobiti za bodove?", "šta sve mogu kupiti za bodove",
            "Za šta mogu potrošiti bodove?", "Koje nagrade mogu uzeti za bodove?",
            "Kako da zamijenim bodove za majicu?", "Koje nagrade imate?"
          ].freeze

          # The directory the defect substituted. Every one of these must stay
          # with the model and the catalogue reader, bank details and all.
          PARTNER_PROMPTS = [
            "Koje organizacije sarađuju sa fondacijom?", "Ko su vaši partneri?",
            "Ko su partneri Lokalne fondacije Bijeljina?", "Koje su partnerske organizacije?",
            "Sa kim sarađujete?", "Koje organizacije podržavate?",
            "Prikaži mi organizacije na platformi."
          ].freeze

          NOW = Time.utc(2026, 9, 14, 12)
          LOCALE_FILES = %w(sr.yml sr-Cyrl.yml bs.yml hr.yml en.yml decidim_bih_dialogue.yml).freeze
          # The directory entry the defect returned, verbatim enough to prove
          # the partner path is untouched.
          ACCOUNT = "555-00000652046-79"
          DIRECTORY_TEXT = "Lokalna fondacija Bijeljina: donacije na račun #{ACCOUNT} ili IBAN BA395550000065058015.".freeze

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
            def call = AdmissionControl::Result.new(status: :admitted, value: yield(TurnBudget.new(timeout: 2)))
          end

          # The production misclassification, frozen: every turn this fixture
          # is asked about comes back as the partner directory.
          class DirectoryClassifier
            attr_reader :calls

            def initialize = @calls = []

            def configured? = true

            def generate_content(**arguments)
              @calls << arguments
              { "action" => "ask_information", "topic" => "community", "entities" => {}, "operation" => "start",
                "needs_clarification" => false, "secondary" => nil, "locale" => "sr" }
            end
          end

          Message = Struct.new(:text, :user, :trusted_context, keyword_init: true) do
            def image_url = nil

            def latitude = nil

            def longitude = nil
          end
          Organization = Struct.new(:id)

          # Stands in for Decidim::Bih::Goodwill::EarningRules — the effective
          # schedule, which is the only place a points value may come from.
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

          # The real Responder chain the secondary read adapter uses, with only
          # the host-wired URLs and the rules object stubbed.
          class PointsResponder < Responder
            def initialize(rules:)
              @organization = Organization.new(7)
              @goodwill_rules = rules
              @goodwill_user_resolver = ->(message) { message.user }
              @classifier = nil
            end

            private

            # lib/decidim/bih.rb is never loaded by a host-free unit test, and
            # this brain is built with no donations provider, so nil is the
            # real behaviour of the handler that would otherwise raise.
            def donation_reply(_message) = nil

            def contribution_url = "/biceriseno/moj-doprinos"

            def sign_in_url = "/users/sign_in"

            def rules_url = "/biceriseno/zajednistvo?tab=kako"

            def log_failure(_code, _error = nil) = nil
          end

          def setup
            @previous = { backend: I18n.backend, load_path: I18n.load_path, available: I18n.available_locales,
                          enforce: I18n.enforce_available_locales, locale: I18n.locale }
            I18n.enforce_available_locales = false
            # A conversation with no saved turn starts in the language the
            # citizen is reading the site in (Coordinator#seed_locale), and
            # this suite's citizen is reading the Serbian site. Minitest alone
            # leaves I18n.locale at its :en default, which would seed every
            # conversation here as English and is an artefact of the harness,
            # not of any host: this engine's four host locales are sr, sr-Cyrl,
            # bs and hr.
            I18n.locale = "sr" # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path = LOCALE_FILES.map { |name| File.expand_path("../../../../../../config/locales/#{name}", __dir__) }
            I18n.backend.send(:init_translations)
            @rules = FakeRules.new({ volunteer_hour: 100, proposal: 25, referral: 25, report: 20,
                                     komsiluk_selected: 10, verification: 10, comment: 3 },
                                   { report: 5, proposal: 1, comment: 5 })
            @classifier = DirectoryClassifier.new
            @reads = []
            @store = StateStore.new(redis: MemoryRedis.new)
            procedures = ProcedureRunner.new(
              read_port: lambda { |**args|
                @reads << args
                Contracts::ReadResult.new(status: "ok", facts: [directory_fact], source: directory_source)
              },
              registration_port: ->(**) { raise "Unexpected account action" },
              destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" }
            )
            @coordinator = Coordinator.new(
              understanding: Understand.new(client: @classifier, wall_clock: -> { NOW }), procedures:,
              state_store: @store, runtime: InlineRuntime.new,
              legacy_secondary: Coordinator::LegacyReadAdapter.new(responder: PointsResponder.new(rules: @rules))
            )
          end

          def teardown
            I18n.locale = @previous.fetch(:locale) # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.backend = @previous.fetch(:backend)
            I18n.load_path = @previous.fetch(:load_path)
            I18n.available_locales = @previous.fetch(:available)
            I18n.enforce_available_locales = @previous.fetch(:enforce)
          end

          # --- selection -----------------------------------------------------

          def test_both_measured_turns_of_the_reproducer_select_the_points_explanation
            REPRODUCER.each do |prompt|
              assert_equal "points_explainer", route_for(prompt), prompt
              read = CivicQuestion.classify(prompt)

              assert_equal "ask_information", read.fetch(:action), prompt
              assert_equal "goodwill", read.fetch(:topic), prompt
              assert_equal "earn", read.dig(:entities, "category"), prompt
              assert CivicQuestion.earning?(prompt), prompt
            end
          end

          def test_every_explanation_phrasing_selects_the_schedule_and_never_a_catalogue_topic
            EXPLANATION_PROMPTS.each do |prompt|
              read = CivicQuestion.classify(prompt)

              refute_nil read, "#{prompt}: left to the model"
              assert_equal "goodwill", read.fetch(:topic), prompt
              assert_equal "earn", read.dig(:entities, "category"), prompt
            end
          end

          # What points ARE and what they BUY are two questions with two
          # reviewed answers. Answering the first with the second is half of
          # the defect this route exists to fix.
          def test_an_exchange_question_is_declined_so_the_rewards_catalogue_keeps_it
            EXCHANGE_PROMPTS.each do |prompt|
              refute_equal "points_explainer", route_for(prompt), prompt
            end
          end

          def test_a_partner_or_organisation_question_is_never_claimed_here
            PARTNER_PROMPTS.each do |prompt|
              assert_nil route_for(prompt), prompt
            end
          end

          # The route is registered last on purpose: it only ever answers what
          # every earlier route declined.
          def test_the_route_is_registered_last_and_no_existing_route_loses_precedence
            assert_equal "points_explainer", DeterministicRoutes.route_names.last
            {
              "kako da zaradim bodove" => "earning",
              "koliko bodova nosi prijava problema" => "earning",
              "Koliko imam bodova?" => "goodwill_balance",
              "moji bodovi" => "goodwill_balance",
              "Koliko košta majica u bodovima?" => "reward_price",
              "Koliko bodova košta pozivnica?" => "launch_topic",
              "imam li pozivnicu" => "invitation",
              "koji je moj komsiluk" => "komsiluk",
              "Kako da doniram?" => "donation_giving"
            }.each { |prompt, route| assert_equal route, route_for(prompt), prompt }
          end

          # CivicQuestion refuses anything over 160 characters; so does this.
          def test_long_prose_never_selects_the_points_explanation
            assert_nil CivicQuestion.classify("#{"a" * 150} sta su bodovi")
            refute PointsExplainerRoute.explanation?(Decidim::Bih::Text.fold("#{"a" * 200} sta su bodovi"),
                                                     "#{"a" * 200} sta su bodovi")
          end

          # --- what the citizen is actually told -----------------------------

          def test_the_reproducer_is_answered_from_the_schedule_without_the_model_or_a_catalogue_read
            REPRODUCER.each_with_index do |prompt, index|
              result = @coordinator.call(message: chat(prompt), context: context("reproducer"))

              assert_equal "answered", result.resolution, prompt
              assert_equal "goodwill", result.reply.answer_intent, prompt
              assert_includes result.reply.text, I18n.t("decidim.bih.concierge.goodwill.earning.intro", locale: "sr"), prompt
              assert_includes result.reply.text, I18n.t("decidim.bih.concierge.goodwill.earning.note", locale: "sr"), prompt
              # The public rules page. Decidim::Bih.public_path is a host
              # method a brain-only unit test never loads, so the documented
              # fallback path is what the answer carries here.
              assert_includes result.reply.text, "zajednistvo?tab=kako", prompt
              assert_equal index + 1, @store.read(context: context("reproducer")).fetch("version"), prompt
            end
            assert_empty @classifier.calls, "the model decided a points question"
            assert_empty @reads, "a points question reached a catalogue read"
          end

          def test_the_answer_carries_no_account_number_catalogue_price_or_partner_profile
            REPRODUCER.each do |prompt|
              text = @coordinator.call(message: chat(prompt), context: context("no-money")).reply.text

              refute_includes text, ACCOUNT, prompt
              refute_match(/\bIBAN\b/i, text, prompt)
              refute_match(%r{naljepnic|cijena u bodovima|organizacija/\d}i, text, prompt)
            end
          end

          # The registration invariant: 20 points, read from the effective
          # schedule, never typed. The answer is the schedule's own numbers.
          def test_the_answer_reads_its_numbers_from_the_effective_schedule
            text = @coordinator.call(message: chat("Šta su bodovi zajedništva?"), context: context("schedule")).reply.text
            registration = I18n.t("decidim.bih.concierge.goodwill.earning.registration", locale: "sr")

            assert_includes text, I18n.t("decidim.bih.concierge.goodwill.earning.line", locale: "sr", label: registration,
                                                                                        points: I18n.t("decidim.bih.concierge.goodwill.earning.points", locale: "sr", count: 20))
            assert_includes text, I18n.t("decidim.bih.goodwill.actions.volunteer_hour", locale: "sr")
          end

          def test_a_cyrillic_question_is_answered_in_cyrillic_from_the_same_schedule
            text = @coordinator.call(message: chat("Шта су бодови заједништва?"), context: context("cyrillic")).reply.text

            assert_includes text, I18n.t("decidim.bih.concierge.goodwill.earning.intro", locale: "sr-Cyrl")
            assert_empty @classifier.calls
          end

          # --- the partner directory must keep working -----------------------

          def test_a_partner_organisation_question_still_reaches_the_model_and_the_directory
            PARTNER_PROMPTS.each_with_index do |prompt, index|
              result = @coordinator.call(message: chat(prompt), context: context("partner-#{index}"))

              assert_equal "community", @reads.last.fetch(:topic), prompt
              assert_includes result.reply.text, ACCOUNT, "#{prompt}: the published partner record was withheld"
            end
            assert_equal PARTNER_PROMPTS.length, @classifier.calls.length
            assert_equal PARTNER_PROMPTS.length, @reads.length
          end

          private

          def route_for(text)
            query = Decidim::Bih::Text.fold(text)
            DeterministicRoutes.routes.find { |route| route.matcher.call(query, text) }&.name
          end

          def chat(text) = Message.new(text:, user: nil, trusted_context: nil)

          def context(key)
            Contracts::TrustedContext.new(organization_id: 1, conversation_key: Digest::SHA256.hexdigest(key),
                                          now: NOW, capabilities: ["public_reads"])
          end

          def directory_source = { "id" => "mi_platform", "label" => "MI PRE(D)UZIMAMO!", "url" => "https://mi.example/biceriseno/organizacija/4" }

          def directory_fact
            { "id" => "organization:4", "kind" => "public_fact", "text" => DIRECTORY_TEXT, "source_id" => "mi_platform" }
          end
        end
      end
    end
  end
end

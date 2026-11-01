# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The emergency path at the REAL coordinator boundary, with the model
        # FORBIDDEN: the understanding port raises if it is called at all, so a
        # passing assertion is proof that no provider was reached, not evidence
        # that one happened to be fast.
        #
        # Every positive scenario and every benign control runs TRIALS times
        # with fresh state, because the defect being fixed here was
        # intermittent: a single green run is exactly what the broken code
        # produced six times out of eight.
        class EmergencyStageTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 12)
          TRIALS = 20
          KEY = StateStore::SAFETY_CONTEXT_KEY
          FIRE_BRIGADE = "123"
          AMBULANCE = "124"
          POLICE = "122"

          ModelCalled = Class.new(StandardError)

          class FakeRedis
            attr_reader :values
            attr_accessor :write_fails

            def initialize
              @values = {}
              @write_fails = false
            end

            def get(key) = @values[key]

            def del(key)
              @values.delete(key)
              1
            end

            def eval(script, keys:, argv:)
              raise "Unexpected script" unless script == StateStore::WRITE_SCRIPT
              raise Redis::BaseError, "synthetic store failure" if write_fails

              stored = @values[keys.first]
              version = stored ? JSON.parse(stored).fetch("version") : 0
              return 0 unless version == argv.first

              @values[keys.first] = argv[1]
              1
            end
          end

          class InlineRuntime
            def initialize(timeout: 1)
              @timeout = timeout
            end

            def call
              AdmissionControl::Result.new(status: :admitted, value: yield(TurnBudget.new(timeout: @timeout)))
            end
          end

          # Refuses the turn the way a saturated deployment does.
          class CapacityRuntime
            def call
              AdmissionControl::Result.new(status: :capacity)
            end
          end

          # Responds to nothing a pre-model stage may call, and raises for
          # anything that reaches the procedures. The counter is what proves a
          # benign control LEFT the emergency path instead of being escalated.
          class RaisingProcedures
            attr_reader :calls

            def initialize
              @calls = 0
            end

            def call(**)
              @calls += 1
              raise ModelCalled, "procedures reached on an emergency turn"
            end
          end

          Message = Data.define(:text, :conversation_context) do
            def image_url = nil

            def latitude = nil

            def longitude = nil
          end

          def setup
            @previous = { backend: I18n.backend, load_path: I18n.load_path, available: I18n.available_locales, locale: I18n.locale }
            I18n.available_locales = Contracts::LOCALES
            I18n.locale = :sr # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.load_path = [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend = I18n::Backend::Simple.new
            I18n.backend.send(:init_translations)
            @model_calls = 0
            @procedure_calls = 0
          end

          def teardown
            I18n.backend = @previous.fetch(:backend)
            I18n.load_path = @previous.fetch(:load_path)
            I18n.available_locales = @previous.fetch(:available)
            I18n.locale = @previous.fetch(:locale) # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
          end

          # --- the stage is registered, and registered FIRST ------------------

          def test_the_emergency_stage_runs_before_every_other_pre_model_stage
            assert_equal "emergency", PreModelStages.stage_names.first
            assert_includes PreModelStages.stage_names, "resume_nothing"
          end

          # --- openers, 20 trials each ---------------------------------------

          # At the coordinator's own boundary the red-zone control reply answers
          # an opener before admission control, which is what keeps an emergency
          # answerable when the deployment is saturated. The card it uses is the
          # all-services one; the SERVICE-SPECIFIC card for the same openers is
          # proven at the host boundary, where production actually answers them
          # (see the host's report_conversation_test).
          def test_every_historical_opener_is_answered_without_a_model_call_in_twenty_trials
            openers.each do |scenario, text|
              TRIALS.times do |trial|
                @model_calls = 0
                result = fresh_turn(text)

                assert_equal "safety", result.reply.answer_intent, "#{scenario} trial #{trial + 1}"
                assert_match(/12[234]/, result.reply.text, "#{scenario} trial #{trial + 1}")
                assert_nil result.reply.report
                assert_equal 0, @model_calls, "#{scenario} reached the model on trial #{trial + 1}"
              end
            end
          end

          def test_every_historical_opener_is_recognised_deterministically
            openers.each do |scenario, text|
              assert Responder.immediate_danger?(text), scenario
              refute_nil EmergencySignal.assess(text), scenario
            end
          end

          # A saturated deployment still answers the emergency: the red-zone
          # reply is composed before any slot is requested.
          def test_a_saturated_deployment_still_answers_an_emergency_opener
            TRIALS.times do
              result = fresh_turn(openers.fetch("b1c27"), runtime: CapacityRuntime.new)

              assert_equal "safety", result.reply.answer_intent
              assert_match(/12[234]/, result.reply.text)
              assert_equal 0, @model_calls
            end
          end

          def test_a_provider_failure_cannot_reach_an_emergency_turn
            failing = ->(**) { raise Understand::ProviderUnavailable, "synthetic provider outage" }
            openers.each_value do |text|
              result = fresh_turn(text, understanding: failing)

              assert_equal "safety", result.reply.answer_intent
              assert_match(/12[234]/, result.reply.text)
            end
          end

          # An emergency wrapped in cancellation wording reaches the stage,
          # because the coordinator suspends its control reply for a cancelled
          # turn. The service line must lead, and nothing may be cancelled,
          # submitted or published on that turn.
          def test_cancellation_wording_does_not_displace_the_emergency
            TRIALS.times do |trial|
              result = fresh_turn("Odustani. Gori mi kuća, šta da radim?")

              assert_equal "safety", result.reply.answer_intent, "trial #{trial + 1}"
              assert result.reply.text.start_with?(card("emergency_fire")), "trial #{trial + 1}: #{result.reply.text}"
              assert_equal 0, @model_calls
              assert_nil result.reply.report
            end
          end

          def test_cancellation_with_danger_keeps_safety_primary_during_overload
            TRIALS.times do
              result = fresh_turn("Odustani. Gori mi kuća, šta da radim?", runtime: CapacityRuntime.new)
              assert_equal Resolution::SAFETY_GUIDANCE, result.resolution
              assert_equal "safety", result.reply.answer_intent
              assert result.reply.text.start_with?(card("emergency_fire"))
              assert_equal 0, @model_calls
              assert_nil result.reply.report
              refute result.handoff_completed
            end
          end

          # --- follow-ups, 20 trials each ------------------------------------

          def test_every_historical_follow_up_names_the_right_service_in_twenty_trials
            follow_ups.each do |scenario, (kind, text, expected, locale)|
              TRIALS.times do |trial|
                redis = FakeRedis.new
                store = seeded_store(redis, kind:)
                result = turn(text, store:)

                assert_equal "safety", result.reply.answer_intent, "#{scenario} trial #{trial + 1}"
                assert_includes result.reply.text, expected, "#{scenario} trial #{trial + 1}"
                assert_includes result.reply.text, card("emergency_disclaimer", locale:), "#{scenario} answers in #{locale}"
                assert_equal 0, @model_calls, "#{scenario} reached the model on trial #{trial + 1}"
                assert_equal 0, @procedure_calls, "#{scenario} reached the procedures on trial #{trial + 1}"
                assert_equal 2, stored_state(store).fetch(KEY).fetch("turns"), "#{scenario} keeps a bounded, counted context"
              end
            end
          end

          def test_a_follow_up_that_says_people_are_beside_it_adds_the_ambulance_line
            redis = FakeRedis.new
            result = turn("Djeca su pored toga sada. Daj broj službe, kratko.", store: seeded_store(redis, kind: "gas"))

            assert_includes result.reply.text, card("emergency_gas")
            assert_includes result.reply.text, card("emergency_also_medical")
            assert_equal 0, @model_calls
          end

          def test_a_safety_reply_leaves_enough_context_for_the_next_turn
            redis = FakeRedis.new
            store = seeded_store(redis, kind: "fire")
            first = turn("Koga da zovem odmah?", store:)
            second = turn("Koji je broj hitne pomoći?", store:)

            assert_includes first.reply.text, FIRE_BRIGADE
            assert_includes second.reply.text, AMBULANCE, "the second follow-up is still inside the emergency"
            assert_equal 3, stored_state(store).fetch(KEY).fetch("turns")
          end

          def test_the_context_stops_following_the_conversation_after_three_turns
            redis = FakeRedis.new
            store = seeded_store(redis, kind: "fire", turns: 3)
            result = turn("Koga da zovem odmah?", store:)

            assert_includes result.reply.text, FIRE_BRIGADE, "the turn that hits the cap is still answered"
            assert_nil stored_state(store).fetch(KEY), "and the context is dropped with it"
          end

          # --- the context never becomes an incident profile -----------------

          def test_an_unrelated_later_question_is_not_reinterpreted_as_an_emergency
            benign_controls.each do |scenario, text|
              TRIALS.times do |trial|
                @model_calls = 0
                redis = FakeRedis.new
                result = turn(text, store: seeded_store(redis, kind: "fire"))

                refute_equal "safety", result.reply.answer_intent, "#{scenario} escalated on trial #{trial + 1}"
                refute_match(/12[234]/, result.reply.text, "#{scenario} escalated on trial #{trial + 1}")
                assert_operator @model_calls + @procedure_calls, :>, 0, "#{scenario} never left the emergency path"
              end
            end
          end

          def test_an_expired_moved_or_reassigned_context_is_not_continued
            # A topic change is the STORE's rule and is proven against the
            # store in safety_context_contract_test: it cannot even be seeded
            # here, because a write with a mismatched topic drops the context.
            [
              ["expired", { now: NOW + StateStore::SAFETY_CONTEXT_TTL + 1 }],
              ["other actor", { actor_id: 99 }]
            ].each do |scenario, options|
              redis = FakeRedis.new
              store = seeded_store(redis, kind: "fire")
              context = context_for(now: options.fetch(:now, NOW), actor_id: options.fetch(:actor_id, 7))
              result = turn("Koga da zovem odmah?", store:, context:)

              refute_equal "safety", result.reply.answer_intent, "#{scenario} kept the emergency context"
              assert_operator @model_calls + @procedure_calls, :>, 0, scenario
            end
          end

          # --- a bare contact question ---------------------------------------

          def test_an_explicit_service_request_is_answered_from_reviewed_contacts
            {
              "Koji je broj vatrogasaca?" => FIRE_BRIGADE,
              "Koji je broj hitne pomoći?" => AMBULANCE,
              "Koga da zovem, policiju?" => POLICE
            }.each do |text, number|
              redis = FakeRedis.new
              result = turn(text, store: StateStore.new(redis:))

              assert_includes result.reply.text, number, text
              assert_equal 0, @model_calls, text
              assert_empty redis.values, "a contact question opens no emergency context"
            end
          end

          # --- failures that must not cost the citizen the card --------------

          def test_a_store_that_cannot_save_still_delivers_the_card
            redis = FakeRedis.new
            store = seeded_store(redis, kind: "medical")
            redis.write_fails = true
            result = turn("Koji je broj hitne pomoći?", store:)

            assert_includes result.reply.text, AMBULANCE
            assert_nil result.state, "a failed save must not be reported as saved"
            assert_equal 0, @model_calls
          end

          # The coordinator refuses a candidate whose CAS it cannot complete
          # (an expired deadline, a concurrent turn). The stage must hand the
          # card back anyway, which is asserted against the stage seam itself.
          def test_a_refused_candidate_still_returns_the_card
            refusal = ProcedureRunner::Result.new(
              state: nil, reply: Responder::Reply.new(text: "context_unavailable", report: nil, answer_intent: "fallback"),
              resolution: "unsupported", fact_ids: [], handoff_offered: false, handoff_completed: false
            )
            store = StateStore.new(redis: FakeRedis.new)
            state = store.empty_state(context_for)
            turn = PreModelStages::Turn.new(
              message: Message.new(text: "Gori mi kuća!", conversation_context: []),
              context: context_for, state:, support: refusing_support(refusal)
            )
            result = EmergencyStage.call(turn)

            assert_includes result.reply.text, FIRE_BRIGADE
            assert_nil result.state, "a refused write must never be reported as saved"
          end

          # --- no dispatch, no promise ---------------------------------------

          def test_no_card_claims_to_call_anyone_or_names_a_waiting_time
            Contracts::LOCALES.each do |locale|
              EmergencyCard::KIND_KEYS.each_key do |kind|
                text = EmergencyCard.call(EmergencySignal::Assessment.new(kind:, also: nil), locale:)

                refute_match(/poslala|poslao|zvala sam|obavijestila sam|dispatch|i have called|on the way|stizu za|minut/i, text, "#{locale}/#{kind}")
                assert_match(/12[34]/, text, "#{locale}/#{kind}")
                assert_includes text, I18n.t("decidim.bih.dialogue.emergency_disclaimer", locale:), "#{locale}/#{kind}"
              end
            end
          end

          private

          def openers
            {
              "repeat-trial noun" => "požar u kontejneru ispred zgrade, šta da radim?",
              "repeat-trial verb" => "gori kontejner ispred zgrade, šta da radim?",
              "b1c06" => "Izlio se neki hemijski otpad iz kamiona kod škole, ima dim, šta da radimo?",
              "b1c27" => "Gori kontejner ispred zgrade!",
              "b1c28" => "Пожар у подруму зграде, шири се дим!",
              "b1c29" => "Treba mi raspored smeća ali HITNO sada požar u kontejneru ispred škole!",
              "b1c30" => "Čovjek se upravo srušio na ulici i ne reaguje, koga da zovem?",
              "b1c31" => "U zgradi jako smrdi na plin i komšija se onesvijestio.",
              "b1c36" => "Voda iz rijeke trenutno ulazi u kuće u Janji, ljudi su unutra. Koga da zovem odmah?",
              "unlisted object" => "Gori krov na susjednoj kući!",
              "english" => "The container is on fire, what do I do?",
              "cyrillic" => "Гори кућа у мојој улици!"
            }
          end

          # scenario => [danger already established, the follow-up, the number
          # it must name, the locale the citizen must be answered in]
          def follow_ups
            {
              "b1c06" => ["gas", "Djeca su pored toga sada. Daj broj službe, kratko.", FIRE_BRIGADE, :sr],
              "b1c27" => ["fire", "Koga da zovem odmah?", FIRE_BRIGADE, :sr],
              "b1c28" => ["fire", "Људи су још унутра. Кога да зовем одмах?", FIRE_BRIGADE, :"sr-Cyrl"],
              "b1c29" => ["fire", "Ovo se dešava sad, nije pitanje o rasporedu.", FIRE_BRIGADE, :sr],
              "b1c30" => ["medical", "Treba mi broj hitne pomoći, odmah.", AMBULANCE, :sr],
              "b1c31" => ["gas", "Koji je broj hitne pomoći?", AMBULANCE, :sr],
              "b1c36" => ["flood", "To je opasnost sada, ne tražim mjerenje vodostaja.", FIRE_BRIGADE, :sr],
              "english" => ["fire", "Who do I call?", FIRE_BRIGADE, :en]
            }
          end

          def benign_controls
            {
              "waste schedule" => "Kad se odvozi smeće u Dvorovima?",
              "parking" => "Koliko košta parking u crvenoj zoni?",
              "thanks then question" => "A kad je sljedeća sjednica skupštine?",
              "hypothetical" => "A šta ako se vrati sutra?",
              "report" => "Prijavljujem oštećenu klupu u parku"
            }
          end

          def card(key, locale: :sr)
            I18n.t("decidim.bih.dialogue.#{key}", locale:, raise: true)
          end

          def context_for(now: NOW, actor_id: 7)
            Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, actor_id:, now:,
                                          capabilities: %w(public_reads report_guidance))
          end

          def seeded_store(redis, kind:, topic: "police", turns: 1, now: NOW)
            store = StateStore.new(redis:)
            context = context_for(now:)
            state = store.empty_state(context).merge(
              "topic" => topic,
              KEY => { "kind" => kind, "topic" => topic, "opened_at" => now.to_f,
                       "expires_at" => now.to_f + StateStore::SAFETY_CONTEXT_TTL, "turns" => turns }
            )
            raise "seed failed" unless store.write(context:, state:, expected_version: 0) == :saved

            store
          end

          def stored_state(store, context: context_for)
            store.read(context:)
          end

          # Everything a stage may reach, with the coordinator's CAS replaced by
          # a refusal. Nothing else is callable, so a stage that tries anything
          # else fails loudly.
          def refusing_support(refusal)
            raising = ->(*) { raise ModelCalled, "stage support reached" }
            PreModelStages::Support.new(
              procedures: RaisingProcedures.new, cancelled: ->(*) { false }, prior_evidence_kind: ->(*) {},
              accept: ->(*, **) { refusal }, unavailable: ->(*) { refusal }, resume_nothing: raising,
              resume_with_nothing_suspended: ->(*) { false }, walking_stop_request: ->(*) { false }
            )
          end

          def fresh_turn(text, **)
            turn(text, store: StateStore.new(redis: FakeRedis.new), **)
          end

          def turn(text, store:, context: context_for, runtime: nil, understanding: nil)
            procedures = RaisingProcedures.new
            coordinator = Coordinator.new(
              understanding: understanding || raising_understanding,
              procedures:,
              state_store: store,
              runtime: runtime || InlineRuntime.new
            )
            result = coordinator.call(message: Message.new(text:, conversation_context: []), context:)
            @procedure_calls = procedures.calls
            if result.reply.answer_intent == "safety"
              assert_equal Resolution::SAFETY_GUIDANCE, result.resolution
              assert_nil result.reply.report
              assert_empty result.fact_ids
              refute result.handoff_offered
              refute result.handoff_completed
            end
            result
          end

          def raising_understanding
            lambda do |**|
              @model_calls += 1
              raise ModelCalled, "understanding reached"
            end
          end
        end
      end
    end
  end
end

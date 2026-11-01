# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/pre_model_stages"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # "Znaš li ko sam ja?" asked by a VERIFIED, SIGNED-IN citizen returned
        # the 253-character anonymous privacy copy on production on 14.09.2026
        # — one turn after Milica had answered "Kako se zovem?" with his name.
        #
        # Both sentences are the same question to a citizen and two different
        # questions to the platform, and the two matchers overlap: the cold
        # privacy card claims "znaš li ko sam" and the own-state identity route
        # claims it too. The card runs as a pre-model stage, so it always won —
        # whether or not the conversation had an actor at all.
        #
        # The privacy copy is right for an anonymous session and false for a
        # resolved one. This suite pins the session-state check that decides
        # between them, in both directions.
        class PublicInformationIdentityStageTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 10, 30)
          ORGANIZATION_ID = 1
          ACTOR_ID = 7
          Message = Data.define(:text)
          # Reaching any other stage helper would mean the card took a path it
          # has never taken; these are here to say so loudly.
          UNREACHABLE = ->(*) { raise "the identity card reaches no other stage helper" }
          PRIVACY_COPY = "ne prepoznaje sam od sebe"
          # The published contact facts the neighbouring cards quote. Without
          # them those cards decline, and "no other card changed" would prove
          # nothing.
          SUPPORT = {
            public_support_name: "Lokalna fondacija Bijeljina",
            public_support_email: "office@fondacijabijeljina.com"
          }.freeze

          def setup
            SUPPORT.each { |name, value| Decidim::Bih.define_singleton_method(name) { value } }
            @original_load_path = I18n.load_path.dup
            @original_available_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @support = PreModelStages::Support.new(
              procedures: nil, cancelled: UNREACHABLE, prior_evidence_kind: UNREACHABLE,
              accept: UNREACHABLE, unavailable: UNREACHABLE, resume_nothing: UNREACHABLE,
              resume_with_nothing_suspended: UNREACHABLE, walking_stop_request: UNREACHABLE,
              retain_answer: ->(state:, **) { state }
            )
          end

          def teardown
            SUPPORT.each_key { |name| Decidim::Bih.singleton_class.send(:remove_method, name) }
            I18n.load_path = @original_load_path
            I18n.available_locales = @original_available_locales
            I18n.backend.reload!
          end

          # An anonymous browser is told the truth: this conversation
          # recognises nobody on its own.
          def test_an_anonymous_session_keeps_the_reviewed_privacy_card
            ["Znaš li ko sam ja?", "Znaš li ko sam?", "Znaš li moje ime?"].each do |text|
              result = answer(text)

              refute_nil result, text
              assert_equal "privacy", result.reply.answer_intent, text
              assert_includes result.reply.text, PRIVACY_COPY, text
            end
          end

          # A citizen this turn's trusted scope actually names is not told the
          # chat cannot recognise them. The card steps aside; it does not
          # answer instead.
          def test_a_resolved_actor_is_never_told_the_chat_cannot_recognise_them
            ["Znaš li ko sam ja?", "Znaš li ko sam?", "Znaš li moje ime?"].each do |text|
              assert_nil answer(text, actor_id: ACTOR_ID), text
            end
          end

          # What answers instead is the EXISTING authorized own-state path: the
          # utterance the card steps aside for is exactly the one the own-state
          # identity route claims, and the Responder's own reader resolves the
          # user, the organization and the trusted scope before it says a name.
          def test_the_turn_it_declines_is_the_own_state_identity_question
            ["Znaš li ko sam ja?", "Znaš li ko sam?", "Znaš li moje ime?"].each do |text|
              assert_equal "identity", CivicQuestion.own_state(text), text
            end
          end

          # The decision is re-taken from the live scope every turn: nothing is
          # cached, so the same words from the same conversation answer
          # differently the moment the actor is gone.
          def test_the_check_is_the_live_scope_and_not_a_memory
            assert_nil answer("Znaš li ko sam ja?", actor_id: ACTOR_ID)
            assert_includes answer("Znaš li ko sam ja?").reply.text, PRIVACY_COPY
          end

          # A privacy question that carries its own "if I am not signed in"
          # condition is NOT an own-state question. It keeps the card whoever
          # asks it — that is the turn the card was written for.
          def test_a_conditional_privacy_question_keeps_the_card_for_everyone
            text = "Da li znaš moje ime ako nisam prijavljen?"

            assert_nil CivicQuestion.own_state(text)
            [nil, ACTOR_ID].each do |actor_id|
              result = answer(text, actor_id:)

              refute_nil result, actor_id.inspect
              assert_includes result.reply.text, PRIVACY_COPY, actor_id.inspect
            end
          end

          # Only this card, and only this question. Every other reviewed card
          # answers a signed-in citizen exactly as it answers an anonymous one.
          def test_no_other_card_changes_with_the_session_state
            ["Utiču li bodovi na glasanje?", "Kako da promijenim broj telefona na nalogu?",
             "Možeš li mi poslati poruku na Viber?"].each do |text|
              signed_in = answer(text, actor_id: ACTOR_ID)

              refute_nil signed_in, text
              assert_equal answer(text).reply.text, signed_in.reply.text, text
            end
          end

          private

          def answer(text, actor_id: nil)
            context = Contracts::TrustedContext.new(
              organization_id: ORGANIZATION_ID, conversation_key: "c" * 64, actor_id:, now: NOW
            )
            turn = PreModelStages::Turn.new(message: Message.new(text:), context:,
                                            state: StateStore.new.empty_state(context), support: @support)
            PublicInformationStage.result_for(turn)
          end
        end
      end
    end
  end
end

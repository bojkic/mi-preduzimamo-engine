# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/pre_model_stages"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # b3c11 — "Da li drugi građani vide broj telefona s mog naloga?" got the
        # account menu twice. The answer is specific, reviewed and the same for
        # every citizen, so it is decided before the model — and before the
        # general privacy card, which would otherwise claim the question and
        # answer it with the privacy policy.
        class AccountPhoneVisibilityStageTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 10, 30)
          Message = Data.define(:text)

          def setup
            @original_load_path = I18n.load_path.dup
            @original_available_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, now: NOW)
            @state = StateStore.new.empty_state(@context)
          end

          def teardown
            I18n.load_path = @original_load_path
            I18n.available_locales = @original_available_locales
            I18n.backend.reload!
          end

          def answer(text, state: @state)
            turn = PreModelStages::Turn.new(message: Message.new(text:), context: @context, state:, support: nil)
            AccountPhoneVisibilityStage.result_for(turn)
          end

          def test_the_number_visibility_question_is_answered_specifically
            result = answer("Da li drugi građani vide broj telefona s mog naloga?")

            assert_equal "answered", result.resolution
            assert_equal "setup", result.reply.answer_intent
            assert_includes result.reply.text, "nije javan"
            assert_equal @state, result.state, "the stage writes no conversation state"
          end

          # The general privacy card matches the same words. The specific answer
          # has to run first or the citizen is handed a policy link instead.
          def test_it_outranks_the_general_privacy_card
            names = PreModelStages.stage_names

            assert_operator names.index("account_phone_visibility_card"), :<, names.index("public_information_card")
            assert_operator names.index("account_phone_visibility_card"), :>, names.index("emergency")
            assert PublicInformation.card("Da li drugi građani vide broj telefona s mog naloga?"),
                   "this test is only meaningful while the privacy card still claims the question"
          end

          def test_it_answers_in_cyrillic_and_declines_everything_else
            cyrillic = answer("Да ли други грађани виде број телефона с мог налога?")

            assert_match(/\p{Cyrillic}/, cyrillic.reply.text)
            ["Zašto tražite broj pri registraciji?", "Kako da se registrujem?", "Ko vidi moju prijavu?",
             "Kako da promijenim broj telefona?", "Gdje mogu pročitati politiku privatnosti ove platforme?"].each do |text|
              assert_nil answer(text), text
            end
          end

          def test_current_sender_observation_is_not_a_public_privacy_policy_answer
            ["Pišem iz Instagrama, vidiš li sada moj broj telefona i koliko imam bodova?",
             "Vidiš li ti moj broj telefona?", "Да ли можеш видјети мој број телефона?",
             "Can you see my phone number and points?", "Do you see my phone number?"].each do |text|
              assert_nil answer(text), text
              refute AccountQuestion.phone_visibility_question?(text), text
              assert_nil PublicInformation.card(text), text
            end
          end

          def test_third_party_exposure_keeps_the_reviewed_policy_card
            ["Ko može vidjeti moj broj telefona?", "Da li drugi vide moj broj telefona?",
             "Is my phone number public?"].each do |text|
              assert_equal "answered", answer(text).resolution, text
              assert_includes answer(text).reply.text, "nije javan"
            end
          end

          def test_a_citizen_in_the_middle_of_a_report_keeps_the_turn
            assert_nil answer("Da li drugi vide moj broj telefona?", state: @state.merge("pending_slot" => "description"))
            assert_nil answer("Da li drugi vide moj broj telefona?", state: @state.merge("draft" => { "id" => "x" }))
          end
        end
      end
    end
  end
end

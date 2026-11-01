# frozen_string_literal: true

require_relative "pre_model_stages"
require_relative "procedure_runner"
require_relative "resolution"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # New evidence about a missing public-read slot can change the question
        # without inventing the slot, a payment instruction, or a feedback vote.
        module FeedbackRecoveryStage
          SIGN_CLUE = /\A(?:oznacio[ ]sam[ ]nije[ ]korisno[ ]jer[ ]jos[ ]ne[ ]znam[ ]koju[ ]zonu[ ]da[ ]platim[ ])?
            (?:(?:nemam[ ]naziv[ ]ulice|ne[ ]znam[ ]ulicu)[ ](?:ali[ ])?)?
            vidim[ ](?:znak[ ]za[ ]parking|parking[ ](?:znak|tablu)|tablu[ ]za[ ]parking)\z/x
          REGULAR_WASTE = /\A(?:pitam[ ]za|pitao[ ]sam[ ]za|pitala[ ]sam[ ]za|zanima[ ]me)[ ]
            (?:redovan[ ]odvoz|raspored[ ]odvoza)(?:[ ](?:smeca|otpada))?
            [ ]ne[ ]zelim[ ](?:da[ ])?prijavim[ ]problem\z/x

          module_function

          def result_for(turn)
            state = turn.state
            return unless pending_public_area?(state)
            return unless turn.text.length <= 240 && turn.context.capabilities.include?("public_reads")
            return if turn.cancelled? || evidence_message?(turn.message)

            query = Decidim::Bih::Text.fold(turn.text)
            key = response_key(state["topic"], query)
            return unless key

            locale = turn.text.match?(/\p{Cyrillic}/) ? "sr-Cyrl" : state.fetch("locale")
            reply = Responder::Reply.new(text: I18n.t("decidim.bih.dialogue.#{key}", locale:, raise: true), report: nil,
                                         quick_replies: [], answer_intent: "service", locale:)
            ProcedureRunner::Result.new(state:, reply:, resolution: Resolution::CLARIFICATION, fact_ids: [],
                                        handoff_offered: false, handoff_completed: false)
          end

          def pending_public_area?(state)
            state.values_at("active_task", "pending_slot") == %w(ask_information area_query) && !state["draft"]
          end

          def evidence_message?(message)
            [:image_url, :dialogue_location, :latitude].any? { |field| message.respond_to?(field) && !message.public_send(field).nil? }
          end

          def response_key(topic, query)
            return "parking_sign_details" if topic == "parking" && SIGN_CLUE.match?(query)

            "regular_waste_location" if topic == "waste" && REGULAR_WASTE.match?(query)
          end
        end

        PreModelStages.register("feedback_recovery", before: "public_information_follow_up") do |turn|
          FeedbackRecoveryStage.result_for(turn)
        end
      end
    end
  end
end

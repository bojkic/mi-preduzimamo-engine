# frozen_string_literal: true

require_relative "pre_model_stages"
require_relative "contracts"
require_relative "procedure_runner"
require_relative "resolution"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A privacy preference while we await a public journey's origin is
        # not a new civic task, nor another failed attempt to supply the slot.
        module TransportLocationPreferenceStage
          REFUSAL = /\A(?:ne\s+(?:zelim|hocu|mogu)\s+(?:slati|dijeliti|deliti|poslati)|necu\s+(?:slati|dijeliti|deliti)|
            i\s+(?:(?:do\s+not|don\s+t|dont)\s+want\s+to|cannot|can\s+not|can\s+t|cant)\s+(?:share|send))\s+
            (?:gps|(?:trenutnu\s+)?lokaciju|(?:my\s+)?location)
            (?:\s+(?:sta|sto)\s+(?:jos\s+)?mogu\s+(?:napisati|navesti)|\s+(?:koja|koje)\s+je\s+alternativa|
            \s+mogu\s+li\s+(?:napisati|navesti|opisati)\s+(?:gdje\s+(?:se\s+nalazim|sam)|gde\s+(?:se\s+nalazim|sam)|adresu|ulicu|mjesto|mesto)|
            \s+what\s+else\s+can\s+i\s+(?:write|provide)|\s+can\s+i\s+(?:write|provide|describe)\s+(?:my\s+address|where\s+i\s+am))?\z/x

          module_function

          # The correction preprocessor uses the same predicate so it does
          # not discard the privacy preference before this stage receives it.
          def handles?(text:, state:)
            state.values_at("active_task", "topic", "pending_slot") == %w(ask_information transport stop) &&
              !state["draft"] && text.length <= 200 && REFUSAL.match?(Decidim::Bih::Text.fold(text))
          end

          def result_for(turn)
            return unless handles?(text: turn.text, state: turn.state)
            return if turn.cancelled?
            return unless turn.context.capabilities.include?("public_reads")
            return if turn.message.respond_to?(:image_url) && turn.message.image_url
            return if turn.message.respond_to?(:dialogue_location) && turn.message.dialogue_location

            locale = turn.text.match?(/\p{Cyrillic}/) ? "sr-Cyrl" : turn.state.fetch("locale")
            reply = Responder::Reply.new(text: I18n.t("decidim.bih.dialogue.transport_location_alternatives", locale:, raise: true),
                                         report: nil, quick_replies: [], answer_intent: "service", locale:)
            ProcedureRunner::Result.new(state: turn.state, reply:, resolution: Resolution::CLARIFICATION,
                                        fact_ids: [], handoff_offered: false, handoff_completed: false)
          end
        end

        # Anchor on the built-in: report_guidance may itself be the file
        # opening the require cycle, before its registration has happened.
        # Its after-public-card registration still places it before us.
        PreModelStages.register("transport_location_preference", before: "public_information_follow_up") do |turn|
          TransportLocationPreferenceStage.result_for(turn)
        end
      end
    end
  end
end

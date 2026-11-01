# frozen_string_literal: true

require_relative "pre_model_stages"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A place hint without a task cannot establish which service to read.
        # Keep the place in the citizen's words; do not infer geography or identity.
        module LocationHelpStage
          module_function

          def question?(text)
            return false unless text.is_a?(String) && text.length <= 160

            query = Text.fold(text)
            query.match?(/\A(?:gps|lokacija)\s+(?:nije\s+dostup(?:an|na)|je\s+nedostup(?:an|na)|ne\s+radi|je\s+iskljucen(?:a)?)(?:\s+(?:u\s+ovoj\s+poruci|na\s+(?:mom\s+)?telefonu))?\z/) ||
              query.match?(/\A(?:mogu|mogu\s+ti)\s+napisati\s+(?:ulicu\s+i\s+orijentir|naziv\s+ulice|javni\s+orijentir)\z/) ||
              query.match?(/\Amoja\s+(?:priblizna\s+)?lokacija\s+je\s+[a-z0-9 ]{2,80}\z/)
          end

          def result_for(turn)
            return unless question?(turn.text)
            return if turn.state["draft"] || turn.state["pending_slot"] == "description"
            return if turn.state["active_task"] || turn.state["suspended_task"]
            return if turn.message.respond_to?(:image_url) && turn.message.image_url
            return if turn.message.respond_to?(:latitude) && turn.message.latitude

            locale = turn.text.match?(/\p{Cyrillic}/) ? "sr-Cyrl" : turn.state.fetch("locale", "sr")
            text = I18n.t("decidim.bih.dialogue.civic_location_help", locale:)
            reply = Responder::Reply.new(text:, report: nil, answer_intent: "help", tone: "core", locale:)
            ProcedureRunner::Result.new(state: turn.state, reply:, resolution: Resolution::ANSWERED,
                                        fact_ids: [], handoff_offered: false, handoff_completed: false)
          end
        end

        PreModelStages.register("generic_location_help", before: "public_information_card") do |turn|
          LocationHelpStage.result_for(turn)
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../service_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        module Procedures
          module CityService
            def self.call(turn)
              return turn.topic_clarification if turn.topic == "unknown" || turn.action == "help"
              return Komsiluk.call(turn) if turn.topic == "neighborhood"
              # Whether Milica supports the topic is decided BEFORE any detail
              # is collected: a topic with no reader or reviewed source family
              # gets an honest limit and a next step, never a day or a place
              # question. Without a host inventory every topic passes.
              return turn.unsupported_topic unless turn.capability_supported?

              entities = turn.service_question_entities
              needs_area = ServiceQuestion::TOPICS.include?(turn.topic) && !ServiceQuestion.directory_lookup?(topic: turn.topic, entities:)
              return turn.clarify("area_query", "ask_area_query") if needs_area && !turn.has_location?

              turn.render_read(turn.read(action: "ask_information", entities:))
            end
          end
        end
      end
    end
  end
end

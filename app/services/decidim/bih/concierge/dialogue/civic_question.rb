# frozen_string_literal: true

require_relative "../../text"
require_relative "deterministic_routes"
require_relative "account_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Closed read questions observed in rated conversations. This only
        # proposes a typed read; the normal task and permission guards still run.
        #
        # The matchers themselves live in DeterministicRoutes, which owns their
        # evaluation order and is where a new deterministic read registers.
        # This module stays the entry point the rest of the dialogue calls.
        module CivicQuestion
          MAX_LENGTH = 160

          module_function

          def classify(text)
            return unless text.is_a?(String) && text.length <= MAX_LENGTH

            query = Text.fold(text)
            if /\A(?:zelim\s+)?provjeriti\s+status\s+prijave\z/.match?(query)
              return { action: "report_status", topic: "report", entities: { "query" => text } }
            end
            if AccountQuestion.facet(text) == "verify"
              return { action: "ask_information", topic: "account", entities: { "query" => text } }
            end
            if /\A(?:ne\s+saljem\s+prijavu\s+)?(?:samo\s+)?pitam\s+(?:gdje|gde)\s+se\s+odlaze\s+staklo\z/.match?(query)
              return { action: "ask_information", topic: "waste", entities: { "query" => "Gdje se odlaže staklo?" } }
            end
            # Explicit delivery trouble is an account recovery question even
            # after another topic; generic absent messages are not enough.
            if AccountQuestion.facet(text) == "message_missing" && /\b(?:kod|sms|verifikacij\w*|nalog\w*)\b/.match?(query)
              return { action: "ask_information", topic: "account", entities: { "query" => text } }
            end

            # The final clause can correct a catalogue question into an
            # earning question. Its positive wording must match in full.
            clause = PersonalReadRoutes.clause(text) || query
            if /\A(?:objasni\s+)?kako\s+se\s+(?:bodovi|poeni)\s+(?:zaradjuju|dobijaju|skupljaju)\z/.match?(clause)
              return { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "earn" } }
            end

            DeterministicRoutes.match(query, text)
          end

          # "invitation", "komsiluk" or nil. Selection only: the Responder still
          # resolves the user and checks the conversation scope before reading.
          def own_state(text)
            return unless text.is_a?(String) && text.length <= MAX_LENGTH

            own_state_category(Text.fold(text))
          end

          def own_state_category(query)
            DeterministicRoutes.own_state_category(query)
          end

          def mz_contact?(text)
            classify(text)&.fetch(:action) == "choose_area"
          end

          # True when the citizen asks how points are earned (the schedule),
          # as opposed to asking about their own balance, level or rank.
          def earning?(text)
            classify(text)&.dig(:entities, "category") == "earn"
          end

          def earning_query?(query)
            DeterministicRoutes.earning_query?(query)
          end
        end
      end
    end
  end
end

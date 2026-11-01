# frozen_string_literal: true

require_relative "contracts"
require_relative "text_predicates"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Closed public-read refinements only. Returns citizen query slots;
        # the existing tenant matcher/calendar remains the source of truth.
        module PublicActivityContinuation
          TOPICS = %w(neighborhood participation volunteer community).freeze
          # The board/area shapes are shared with ProcedureRunner through TextPredicates; these names stay for external references.
          PRIVATE_CONTEXT = TextPredicates::BOARD_CONTEXT
          QUALIFIED_AREA = TextPredicates::QUALIFIED_AREA
          EXTRA_CLAUSE = TextPredicates::AREA_EXTRA_CLAUSE
          CALENDAR = {
            "danas" => "danas", "sutra" => "sutra", "today" => "today", "tomorrow" => "tomorrow",
            "ovog vikenda" => "ovog vikenda", "ovaj vikend" => "ovaj vikend", "this weekend" => "this weekend",
            "sljedeceg vikenda" => "sljedeceg vikenda", "sledeceg vikenda" => "sledeceg vikenda",
            "sljedeci vikend" => "sljedeci vikend", "sledeci vikend" => "sledeci vikend",
            "narednog vikenda" => "narednog vikenda", "naredni vikend" => "naredni vikend", "next weekend" => "next weekend"
          }.freeze

          module_function

          def call(text:, state:, locale:)
            return unless text.is_a?(String) && text.length.between?(1, 160) && public_context?(state)

            if (area = area_correction(text))
              return input(state, locale, { "area_query" => area })
            end
            return unless citizen_area?(state)

            expression = calendar_follow_up(text, state)
            input(state, locale, { "time_expression" => expression }) if expression
          end

          def public_context?(state)
            state["active_task"] == "ask_information" && TOPICS.include?(state["topic"]) && !state["draft"] &&
              state.dig("prior_evidence", "kind") != "member_board" && !TextPredicates.board_context?(Text.fold(state.dig("entities", "query")))
          end

          def citizen_area?(state)
            keys = %w(area_query area_slug street address).reject { |key| state.dig("entities", key).to_s.empty? }
            keys.intersect?(%w(area_query area_slug)) && keys.all? { |key| %w(citizen corrected).include?(state.dig("entity_provenance", key)) }
          end

          def area_correction(text)
            matched = text.strip.match(/\A(?:(?:ne|не|no)[, ]+)?(?:mislim na|мислим на|i mean)\s+(?<area>.+)\z/i)
            return unless matched

            area = matched[:area].strip.sub(/[.!?]\z/, "")
            return unless area.match?(/\A[\p{L}\p{M}\d .,'’()\-]+\z/u)

            folded = Text.fold(area)
            area if TextPredicates.qualified_area?(folded)
          end

          def calendar_follow_up(text, state)
            folded = Text.fold(text)
            prefix = folded.match(/\A(?:a|and|ne|no) (?<expression>.+)\z/)
            return unless prefix || state["pending_slot"] == "time_expression"

            CALENDAR[prefix ? prefix[:expression] : folded]
          end

          def input(state, locale, entities)
            # Same-task correction invalidates only dependent location/date
            # slots through the normal transition; query/category stay intact.
            Contracts::Understanding.parse(action: "ask_information", topic: state.fetch("topic"), entities:,
                                           operation: "correct", needs_clarification: false, secondary: nil, locale:)
          end
        end
      end
    end
  end
end

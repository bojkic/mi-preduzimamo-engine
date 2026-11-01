# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      # Only server-owned result types can prove a workflow outcome. In
      # particular, a repeated receipt is an acknowledgment, not a new effect.
      #
      # Besides the outcome dimensions, a typed dialogue result exposes the
      # structured facts of the turn — the active task, the pending slot, the
      # clarification count and the entity KEYS — as bounded tokens. These are
      # what the per-turn log and the widget's consent offer read; no value
      # here can ever carry citizen text (entity VALUES are never exposed).
      module ReplyOutcome
        Value = Data.define(:topic, :dimensions, :factual_history, :action, :clarification_count, :pending_slot, :entity_keys) do
          def initialize(topic:, dimensions:, factual_history:, action: nil, clarification_count: 0, pending_slot: nil, entity_keys: [])
            super
          end
        end
        TOKEN = /\A[a-z][a-z0-9_]{0,39}\z/
        MAX_CLARIFICATION_COUNT = 9
        MAX_ENTITY_KEYS = 12

        module_function

        def from(result)
          if result.is_a?(Dialogue::ProcedureRunner::Result)
            dimensions = UsageAggregateRecorder.outcome_dimensions(
              resolution: result.resolution, handoff_offered: result.handoff_offered,
              handoff_completed: result.handoff_completed, grounded_answer: result.fact_ids.any?, action_receipt: false
            )
            state = result.state.is_a?(Hash) ? result.state : {}
            Value.new(
              topic: AnswerOutcome.topic(state["topic"]), dimensions:, factual_history: result.fact_ids.any?,
              action: token(state["active_task"]), clarification_count: bounded_count(state["clarification_count"]),
              pending_slot: token(state["pending_slot"]), entity_keys: entity_keys(state["entities"])
            )
          elsif defined?(ConfirmedReportSubmission::Receipt) && result.is_a?(ConfirmedReportSubmission::Receipt)
            fresh = result.replayed == false
            dimensions = UsageAggregateRecorder.outcome_dimensions(
              resolution: fresh ? "submitted" : "answered", action_receipt: fresh
            )
            Value.new(topic: "report", dimensions:, factual_history: true)
          end
        end

        # A lowercase identifier or nil. Anything else — including anything
        # that could be typed by a citizen — is dropped, not truncated.
        def token(value)
          text = value.to_s
          text if TOKEN.match?(text)
        end

        def bounded_count(value)
          value.is_a?(Integer) ? value.clamp(0, MAX_CLARIFICATION_COUNT) : 0
        end

        def entity_keys(entities)
          return [] unless entities.is_a?(Hash)

          entities.keys.filter_map { |key| token(key) }.sort.first(MAX_ENTITY_KEYS)
        end
      end
    end
  end
end

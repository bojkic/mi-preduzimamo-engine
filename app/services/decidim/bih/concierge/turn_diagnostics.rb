# frozen_string_literal: true

require "json"
require_relative "reply_outcome"

module Decidim
  module Bih
    module Concierge
      # Diagnostic mode for synthetic runs (MILICA_DIAGNOSTIC=1): one JSON line
      # per web-chat turn describing HOW the turn was answered — the route,
      # whether the model was called, how many reads ran, why a detail was
      # asked for, which task transition happened and what the capability
      # gate decided — as bounded tokens, counts and booleans. Never citizen
      # text, entity values, a session, a location or provider output.
      #
      # Off by default. When off, nothing here runs and no turn changes.
      module TurnDiagnostics
        ENV_KEY = "MILICA_DIAGNOSTIC"
        LOG_TAG = "[MilicaDiag]"
        # The Gemini client instruments every request it makes; the number of
        # those events during one turn is the model-call signal.
        MODEL_EVENT = "decidim_bih.gemini.generate_content"
        KEYS = %w(route model_called read_count missing_field_reason transition resolution topic action ms capability_gate).freeze
        ROUTES = %w(control fast_path model secondary report_wrapper).freeze
        # "refused" names a turn whose transition the runner declined. It used
        # to report "none", which is also what a guarded reply and the
        # empty-understanding fallback report — three different turns, one
        # token, and no way to tell them apart in a diagnostic run.
        TRANSITIONS = %w(start continue correct switch cancel resume refused none).freeze
        GATES = %w(supported unsupported skipped).freeze
        MAX_COUNT = 999_999

        module_function

        def enabled?(env = ENV)
          env[ENV_KEY] == "1"
        end

        def line(**)
          "#{LOG_TAG} #{JSON.generate(payload(**))}"
        end

        # +outcome+ is the reply's dialogue outcome (a ProcedureRunner::Result,
        # a report receipt, or nil); +model_calls+ the provider requests seen
        # during the turn; the rest are the turn log's already-typed tokens.
        def payload(outcome:, model_calls:, resolution:, topic:, action:, elapsed_ms:) # rubocop:disable Metrics/ParameterLists
          diag = procedure_diagnostics(outcome)
          model_called = count(model_calls).positive?
          {
            "route" => route(outcome, model_called:),
            "model_called" => model_called,
            "read_count" => count(diag["read_count"]),
            "missing_field_reason" => token(diag["missing_field_reason"]),
            "transition" => enum(diag["transition"], TRANSITIONS, "none"),
            "resolution" => token(resolution) || "unknown",
            "topic" => token(topic) || "unknown",
            "action" => token(action) || "unknown",
            "ms" => count(elapsed_ms),
            "capability_gate" => enum(diag["capability_gate"], GATES, "skipped")
          }
        end

        # report_wrapper: a durable report receipt.
        # fast_path / model: the procedures answered (the result carries their
        #   diagnostics), from a deterministic understanding or after a model call.
        # control: no procedure ran and no model was called — a control reply,
        #   "nothing to resume", or a failure before any procedure.
        # secondary: the model was consulted and the legacy read adapter
        #   answered (a result with state but no procedure diagnostics).
        # model, without a procedure result: the model was called and nothing
        #   answered (a provider failure); the resolution says which.
        def route(outcome, model_called:)
          return "report_wrapper" if report_receipt?(outcome)
          return model_called ? "model" : "fast_path" if procedure_result?(outcome) && !outcome.diagnostics.nil?
          return "control" unless model_called

          procedure_result?(outcome) && outcome.state ? "secondary" : "model"
        end

        def procedure_diagnostics(outcome)
          value = procedure_result?(outcome) ? outcome.diagnostics : nil
          value.is_a?(Hash) ? value : {}
        end

        def procedure_result?(outcome)
          outcome.respond_to?(:diagnostics) && outcome.respond_to?(:state) && outcome.respond_to?(:resolution)
        end

        def report_receipt?(outcome)
          defined?(ConfirmedReportSubmission::Receipt) && outcome.is_a?(ConfirmedReportSubmission::Receipt)
        end

        def token(value)
          ReplyOutcome.token(value)
        end

        def enum(value, allowed, default)
          allowed.include?(value) ? value : default
        end

        def count(value)
          value.is_a?(Integer) ? value.clamp(0, MAX_COUNT) : 0
        end
      end
    end
  end
end

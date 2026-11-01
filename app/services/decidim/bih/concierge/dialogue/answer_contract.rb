# frozen_string_literal: true

require "json"
require_relative "contracts"
require_relative "answer_urls"
require_relative "claim_contract"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Structural/current-citation checks, not a claim of semantic truth.
        # Relational correctness still requires source-based quality evaluation.
        class AnswerContract
          KINDS = %w(answer clarification limitation acknowledgment).freeze
          SCHEMA = {
            "type" => "object", "additionalProperties" => false,
            "properties" => {
              "kind" => { "type" => "string", "enum" => KINDS,
                          "description" => "answer: facts supported by current citations; limitation: explain insufficient evidence without unsupported facts; " \
                                           "clarification: ask for missing information; acknowledgment: harmless closing without facts or actions" },
              "answer" => { "type" => "string", "minLength" => 1, "maxLength" => 2000 },
              "evidence_ids" => { "type" => "array", "maxItems" => 40, "items" => { "type" => "string" },
                                  "description" => "Current record handles supporting this reply. Required for factual answers except a complete scoped zero-result." },
              "claim_selections" => ClaimContract::SCHEMA
            }, "required" => %w(kind answer evidence_ids)
          }.freeze

          # Keep provider decoding structural and stable. Current source identity
          # is checked locally after generation, never encoded as a growing enum.
          def schema(evidence: nil) # rubocop:disable Lint/UnusedMethodArgument -- compatible contract interface
            JSON.parse(JSON.generate(SCHEMA))
          end

          def call(payload:, evidence:, message:, context:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Lint/UnusedMethodArgument -- uniform public contract API
            raise Contracts::Invalid, "Invalid public answer" unless payload.is_a?(Hash) &&
              (payload.keys - %w(answer evidence_ids kind claim_selections)).empty? &&
              (payload.keys & %w(answer evidence_ids kind)).size == 3
            raise Contracts::Invalid, "Invalid public answer kind" unless KINDS.include?(payload["kind"])

            text = Contracts.text!(payload["answer"], limit: 2000)
            raise Contracts::Invalid, "Empty public answer" unless text.match?(/[[:alnum:]]/)

            citations = payload["evidence_ids"]
            records, candidates = ids(evidence)
            allowed = payload["kind"] == "answer" ? records : records + candidates
            unless citations.is_a?(Array) && citations.size <= 40 && citations.uniq == citations && (citations - allowed).empty?
              raise Contracts::Invalid, "Invalid current citations"
            end
            selections = ClaimContract.new.call(selections: payload.fetch("claim_selections", []), cited_ids: citations, evidence:)
            scoped_empty = selections.any? { |claim| claim.fetch("kind") == "scoped_no_match" }
            raise Contracts::Invalid, "Answer requires evidence" if payload["kind"] == "answer" && citations.empty? && !scoped_empty
            raise Contracts::Invalid, "Invalid current citations" if payload["kind"] == "acknowledgment" && (citations.any? || selections.any?)

            AnswerUrls.new(evidence).validate!(text)
            raise Contracts::Invalid, "Answer deadline exceeded" if context.deadline.expired?

            Contracts.snapshot(payload)
          end

          # A lexical mismatch is only a diagnostic. A faithful paraphrase can
          # introduce HH:MM, while a matching clock can still describe the wrong
          # journey. Source-based semantic evaluation determines correctness.
          def unmatched_clock_literal_count(payload:, evidence:, message:)
            source = JSON.generate(evidence)
            text = payload.fetch("answer").gsub(%r{https?://[^\s<>]+}, "")
            clocks = text.scan(/\b(?:[01]?\d|2[0-3]):[0-5]\d\b/).uniq
            clocks.count { |clock| !(source.include?(clock) || message.include?(clock)) }
          end

          # Remove redundant inventories and a byte-identical nested text copy.
          # The top-level text, facts, limits and relationships remain available;
          # canonical envelopes are never changed.
          def for_model(envelope)
            copy = envelope.dup
            copy["query_scope"] = envelope.fetch("query_scope", {}).except("source_ids")
            copy["evidence"] = envelope.fetch("evidence", []).map do |record|
              facts = record["facts"]
              source_fact = facts.is_a?(Hash) ? facts["source_fact"] : nil
              if source_fact.is_a?(Hash) && source_fact["text"] == record["text"]
                record.merge("facts" => facts.merge("source_fact" => source_fact.except("text")))
              else
                record
              end
            end
            copy
          end

          private

          def ids(evidence)
            [evidence.flat_map { |item| item.fetch("evidence", []).map { |record| record.fetch("id") } },
             evidence.flat_map { |item| item.fetch("candidates", []).map { |record| record.fetch("id") } }]
          end
        end
      end
    end
  end
end

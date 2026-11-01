# frozen_string_literal: true

require_relative "contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Validates only the shape and current identity of factual selections.
        # The host checks local relationships and renders their citizen text.
        class ClaimContract
          KINDS = %w(affected_area uncertain_area selected_journey first_departure last_departure scoped_no_match other_fact).freeze
          MAX_SELECTIONS = 12
          SCHEMA = { "type" => "array", "maxItems" => MAX_SELECTIONS, "items" => {
            "type" => "object", "additionalProperties" => false,
            "properties" => { "kind" => { "type" => "string", "enum" => KINDS },
                              "evidence_id" => { "type" => "string", "maxLength" => 160 } },
            "required" => ["kind"]
          } }.freeze

          def call(selections:, cited_ids:, evidence:)
            raise Contracts::Invalid, "Invalid claim selection" unless selections.is_a?(Array) && selections.size <= MAX_SELECTIONS

            records = evidence.flat_map { |envelope| envelope.fetch("evidence", []) }
            by_id = records.to_h { |record| [record.fetch("id"), record] }
            normalized = selections.map do |selection|
              unless selection.is_a?(Hash) && (selection.keys - %w(kind evidence_id)).empty? &&
                     KINDS.include?(selection["kind"])
                raise Contracts::Invalid, "Invalid claim selection"
              end
              kind = selection.fetch("kind")
              id = selection["evidence_id"]
              if kind == "scoped_no_match"
                raise Contracts::Invalid, "Invalid claim selection" unless id.nil? && complete_empty_scope?(evidence)
              elsif !id.is_a?(String) || !by_id.key?(id) || !cited_ids.include?(id)
                raise Contracts::Invalid, "Invalid claim selection"
              end
              selection
            end
            Contracts.snapshot(normalized)
          end

          private

          def complete_empty_scope?(evidence)
            evidence.any? do |envelope|
              envelope["status"] == "empty" && envelope["coverage_complete"] == true &&
                envelope.fetch("query_scope", {})["operation"].is_a?(String)
            end
          end
        end
      end
    end
  end
end

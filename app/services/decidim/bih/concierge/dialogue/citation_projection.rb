# frozen_string_literal: true

require "securerandom"
require_relative "contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Per-turn model-facing handles. Canonical evidence remains unchanged and
        # is reauthorized independently; a handle never grants source authority.
        class CitationProjection
          SOURCE_IDENTITY_FIELDS = %w(id source_id document_id revision).freeze

          def initialize
            @namespace = SecureRandom.hex(4)
            @records = {}
            @handles = {}
          end

          def for_model(envelope)
            copy = envelope.dup
            %w(evidence candidates).each do |kind|
              copy[kind] = envelope.fetch(kind).map do |record|
                # A candidate's selection_key is public reader input, distinct
                # from citation identity; keep it available for the next read.
                project_record(record).merge("id" => handle(kind, record))
              end
            end
            copy
          end

          def canonical_payload(payload)
            return payload unless payload.is_a?(Hash) && payload["evidence_ids"].is_a?(Array)

            ids = payload.fetch("evidence_ids")
            raise Contracts::Invalid, "Too many citations" if ids.size > 40

            canonical = payload.merge("evidence_ids" => ids.map { |id| canonical_handle(id) })
            return canonical unless payload["claim_selections"].is_a?(Array)

            canonical.merge("claim_selections" => payload.fetch("claim_selections").map do |selection|
              next selection unless selection.is_a?(Hash) && selection.has_key?("evidence_id")

              selection.merge("evidence_id" => canonical_handle(selection.fetch("evidence_id")))
            end)
          end

          private

          def canonical_handle(id)
            raise Contracts::Invalid, "Unknown current citation handle" unless id.is_a?(String) && @handles.has_key?(id)

            @handles.fetch(id)
          end

          # PublicToolEvidence wraps the reader's original fact here. These
          # identity fields describe provenance, not separate citeable records.
          # Never recurse through arbitrary facts: journey/catalog IDs are data.
          def project_record(record)
            copy = record.except("document_id")
            facts = record["facts"]
            return copy unless facts.is_a?(Hash) && facts["source_fact"].is_a?(Hash)

            fact = facts.fetch("source_fact").except(*SOURCE_IDENTITY_FIELDS)
            fact["source"] = fact["source"].except(*SOURCE_IDENTITY_FIELDS) if fact["source"].is_a?(Hash)
            copy.merge("facts" => facts.merge("source_fact" => fact))
          end

          def handle(kind, record)
            key = [kind, record.fetch("id")]
            previous = @records[key]
            if previous
              raise Contracts::Invalid, "Conflicting citation identity" unless previous.fetch(:record) == record

              return previous.fetch(:handle)
            end
            value = "e#{@namespace}_#{@handles.size + 1}"
            @records[key] = { record: record, handle: value }
            @handles[value] = record.fetch("id")
            value
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/read_tool_registry"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/turn_budget"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ReadToolRegistryTest < Minitest::Test
          def setup
            @clock = 10.0
            @budget = TurnBudget.new(timeout: 9, clock: -> { @clock })
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, capabilities: ["public_reads"], deadline: @budget)
            @calls = []
            @eligible = true
            @policy = ->(**) { @eligible }
            @record = { "id" => "e1", "document_id" => "line-p9", "revision" => "r1", "text" => "Reviewed public fixture",
                        "facts" => { "origin_id" => "nas", "destination_id" => "janja" } }
            @envelope = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "ok", evidence: [@record])
            handler = lambda do |arguments:, context:|
              @calls << [arguments, context]
              @envelope
            end
            @definition = { "name" => "resolve_stops", "description" => "Resolve a public stop description", "parameters" => {
              "type" => "object", "properties" => { "query" => { "type" => "string", "maxLength" => 160, "minLength" => 1 } },
              "required" => ["query"], "additionalProperties" => false
            }, "handler" => handler }
            @registry = ReadToolRegistry.new(definitions: [@definition])
          end

          def test_only_validated_arguments_reach_server_handler_with_original_scope
            answer = call
            assert_same @envelope, answer
            assert_same @context, @calls.first.last
            assert @calls.first.first.frozen?
            refute @registry.declarations.first.has_key?("handler")
            refute answer.for_prompt(context: @context, eligibility: @policy).has_key?("organization_id")
          end

          def test_unknown_tool_and_injected_authority_never_call_handler
            assert_raises(Contracts::Invalid) { call(name: "submit_report") }
            assert_raises(Contracts::Invalid) { call(arguments: { "query" => "NAS", "organization_id" => 2 }) }
            assert_raises(Contracts::Invalid) { call(arguments: { "query" => ["NAS"] }) }
            assert_raises(Contracts::Invalid) { call(arguments: { "query" => "x" * 161 }) }
            assert_empty @calls
          end

          def test_schema_cannot_expose_an_authority_or_arbitrary_endpoint
            @definition["parameters"]["properties"]["endpoint"] = { "type" => "string", "maxLength" => 100 }
            assert_raises(Contracts::Invalid) { ReadToolRegistry.new(definitions: [@definition]) }
          end

          def test_private_scope_and_expired_budget_do_not_dispatch
            @context = @context.with(capabilities: [])
            assert_raises(Contracts::Invalid) { call }
            @context = @context.with(capabilities: ["public_reads"])
            @clock = 20.0
            assert_raises(Contracts::Invalid) { call }
            assert_empty @calls
          end

          def test_late_result_is_not_accepted
            @definition["handler"] = lambda { |**|
              @clock = 20.0
              @envelope
            }
            @registry = ReadToolRegistry.new(definitions: [@definition])
            assert_raises(Contracts::Invalid) { call }
          end

          def test_wrong_tenant_and_revoked_results_are_rejected
            @envelope = EvidenceEnvelope.new(organization_id: 2, registry_epoch: "r1", status: "ok", evidence: [@record])
            assert_raises(Contracts::Invalid) { call }
            @envelope = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "ok", evidence: [@record])
            call
            @eligible = false
            assert_raises(Contracts::Invalid) { @envelope.for_prompt(context: @context, eligibility: @policy) }
          end

          def test_unknown_or_incomplete_coverage_is_not_asserted_as_empty
            assert_raises(Contracts::Invalid) { EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "empty") }
            assert_raises(Contracts::Invalid) { EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "unavailable", evidence: [@record]) }
            result = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "empty", coverage_complete: true,
                                          query_scope: { "operation" => "plan_journey", "source_ids" => ["p9"] })
            assert_equal true, result.for_prompt(context: @context, eligibility: @policy).fetch("coverage_complete")
          end

          def test_record_copy_is_immutable_and_does_not_freeze_caller
            @record["facts"]["origin_id"] = "wrong"
            assert_equal "nas", @envelope.evidence.first.fetch("facts").fetch("origin_id")
            assert_raises(FrozenError) { @envelope.evidence.first.fetch("facts")["origin_id"] = "wrong" }
            assert_raises(Contracts::Invalid) { EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "ok", evidence: [@record, @record]) }
          end

          def test_private_fields_and_credential_source_urls_are_rejected
            assert_raises(Contracts::Invalid) { EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "ok", evidence: [@record.merge("actor_id" => 1)]) }
            assert_raises(Contracts::Invalid) { EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "ok", evidence: [@record.merge("source_url" => "https://secret@example.com/path")]) }
          end

          def test_empty_results_and_candidates_cannot_bypass_revocation
            empty = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "empty", coverage_complete: true,
                                         query_scope: { "operation" => "plan_journey", "source_ids" => ["p9"] })
            @eligible = false
            assert_raises(Contracts::Invalid) { empty.for_prompt(context: @context, eligibility: @policy) }
            candidate = { "id" => "nas", "document_id" => "stops", "revision" => "r1", "label" => "Bijeljina (NAS)" }
            ambiguous = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "ambiguous", candidates: [candidate])
            policy = ->(record:, **) { record.nil? }
            assert_raises(Contracts::Invalid) { ambiguous.for_prompt(context: @context, eligibility: policy) }
          end

          def test_candidates_and_warnings_cannot_carry_unprojected_private_payloads
            assert_raises(Contracts::Invalid) do
              EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "ambiguous", candidates: [{ "actor_id" => 1, "secret" => "private" }])
            end
            assert_raises(Contracts::Invalid) do
              EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "not_authorized", warnings: [{ "secret" => "private" }])
            end
          end

          def test_malformed_schema_never_silently_weakens_validation
            property = @definition.fetch("parameters").fetch("properties").fetch("query")
            [{ "enum" => "NAS" }, { "enum" => [1] }, { "minLength" => -1 },
             { "minLength" => 170 }, { "minimum" => "bad" }].each do |invalid|
              @definition["parameters"]["properties"]["query"] = property.merge(invalid)
              assert_raises(Contracts::Invalid) { ReadToolRegistry.new(definitions: [@definition]) }
            end
          end

          def test_bounded_nested_tool_schema_round_trips
            leaf = { "type" => "string", "maxLength" => 100 }
            nested = { "type" => "object", "properties" => { "label" => leaf }, "required" => ["label"], "additionalProperties" => false }
            @definition["parameters"]["properties"]["query"] = nested
            registry = ReadToolRegistry.new(definitions: [@definition])
            result = registry.call(name: "resolve_stops", arguments: { "query" => { "label" => "NAS" } }, context: @context, eligibility: @policy)
            assert_same @envelope, result
          end

          def test_large_evidence_rejected_before_projecting_records
            assert_raises(Contracts::Invalid) do
              EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "ok", evidence: Array.new(513, @record))
            end
            assert_raises(Contracts::Invalid) do
              EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "ok", evidence: [@record.merge("text" => "x" * (EvidenceEnvelope::MAX_BYTES + 1))])
            end
          end

          def test_query_scope_is_not_an_arbitrary_metadata_channel
            assert_raises(Contracts::Invalid) do
              EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r", status: "empty", coverage_complete: true,
                                   query_scope: { "operation" => { "actor_id" => 1 } })
            end
          end

          private

          def call(name: "resolve_stops", arguments: { "query" => "NAS" })
            @registry.call(name: name, arguments: arguments, context: @context, eligibility: @policy)
          end
        end
      end
    end
  end
end

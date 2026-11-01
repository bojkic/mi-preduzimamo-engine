# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "test_helper"
require "ostruct"
require "pp"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/model_led_conversation"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/turn_budget"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ModelLedConversationTest < Minitest::Test
          def setup
            @clock = 0.0
            @budget = TurnBudget.new(timeout: 9, clock: -> { @clock })
            @context = Contracts::TrustedContext.new(organization_id: 1, actor_id: 2, conversation_key: "a" * 64,
                                                     capabilities: ["public_reads"], now: Time.utc(2026, 9, 16), deadline: @budget)
            @eligible = true
            @reads = []
            @parameters = { "type" => "object", "properties" => { "query" => { "type" => "string", "maxLength" => 160 } }, "required" => ["query"],
                            "additionalProperties" => false }
            @envelope = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "ok", evidence: [
                                               { "id" => "r1", "document_id" => "source", "revision" => "v1", "text" => "Public timetable",
                                                 "facts" => { "departure" => "06:27", "stop_id" => "nas" } }
                                             ])
            @registry = ReadToolRegistry.new(definitions: [{ "name" => "read", "description" => "Public read", "parameters" => @parameters,
                                                             "handler" => lambda { |arguments:, context:|
                                                               @reads << [arguments, context]
                                                               @envelope
                                                             } }])
            @requests = []
            @phases = []
            @events = []
            @responses = []
            owner = self
            @client = Object.new
            @client.define_singleton_method(:generate_content) { |**request| owner.send(:respond, request) }
            @accounting = lambda { |component:, deadline:, &block|
              @phases << [component, deadline]
              block.call
            }
          end

          def respond(request)
            @requests << request
            response = @responses.shift
            response.respond_to?(:call) ? response.call : response
          end

          def runtime(**)
            ModelLedConversation.new(client: @client, registry: @registry, eligibility: ->(**) { @eligible }, accounting: @accounting,
                                     system_instruction: "Use public sources.", observer: ->(**event) { @events << event }, **)
          end

          def final(kind: "answer", ids: :current, text: "Polazak je u 06:27.")
            if ids == :current
              contents = @requests.last&.fetch(:contents, []) || []
              parts = contents.last&.fetch("parts", []) || []
              record = parts.filter_map { |part| part.dig("functionResponse", "response", "evidence", 0) }.first
              ids = record ? [record.fetch("id")] : []
            end
            OpenStruct.new(function_calls: [], content: { "role" => "model", "parts" => [{ "text" => "structured" }] },
                           structured: { "kind" => kind, "answer" => text, "evidence_ids" => ids }, finish_reason: "STOP", usage: { "promptTokenCount" => 10 })
          end

          def calls(*names)
            values = names.map.with_index { |name, index| { "name" => name, "args" => { "query" => "Janja#{index}" }, "id" => "call#{index}" } }
            OpenStruct.new(function_calls: values, content: { "role" => "model", "parts" => values.map do |call|
              { "functionCall" => call, "thoughtSignature" => "secret-signature" }
            end },
                           finish_reason: "STOP", usage: { "promptTokenCount" => 10 })
          end

          def declaration_fixture(prefix, count)
            Array.new(count) do |index|
              { "name" => "#{prefix}_#{index}", "description" => "Authored bounded declaration",
                "parameters" => @parameters, "handler" => ->(**) { @reads << index; @envelope } }
            end
          end

          def test_full_host_catalogue_accepts_twenty_nine_reads_and_four_protected_proposals
            @registry = ReadToolRegistry.new(definitions: declaration_fixture("read_bound", 29))
            @responses << final(kind: "clarification", ids: [], text: "Koji javni izvor želiš?")
            result = runtime(protected_tools: declaration_fixture("protected_bound", 4)).call(message: "Pomoć", context: @context)
            assert_equal 33, @requests.first.fetch(:tools).first.fetch("functionDeclarations").size
            assert_equal 1, result.model_calls
            assert_equal 0, result.tool_calls
            assert_empty @reads
          end

          def test_combined_declaration_ceiling_is_finite_and_independent_of_each_registry
            @registry = ReadToolRegistry.new(definitions: declaration_fixture("read_bound", 32))
            assert_instance_of ModelLedConversation, runtime(protected_tools: declaration_fixture("protected_bound", 8))
            assert_raises(Contracts::Invalid) { runtime(protected_tools: declaration_fixture("protected_bound", 9)) }
            assert_raises(Contracts::Invalid) { ReadToolRegistry.new(definitions: declaration_fixture("read_bound", 33)) }
          end

          def test_combined_catalogue_still_rejects_public_and_protected_name_collisions
            @registry = ReadToolRegistry.new(definitions: declaration_fixture("read_bound", 29))
            assert_raises(Contracts::Invalid) { runtime(protected_tools: declaration_fixture("read_bound", 1)) }
          end

          def test_larger_declaration_catalogue_does_not_expand_the_default_execution_budget
            @registry = ReadToolRegistry.new(definitions: declaration_fixture("read_bound", 29))
            @responses << calls(*Array.new(9, "read_bound_0"))
            error = assert_raises(ModelLedConversation::Error) do
              runtime(protected_tools: declaration_fixture("protected_bound", 4)).call(message: "Pomoć", context: @context)
            end
            assert_equal "read_round_exceeded", error.code
            assert_empty @reads
          end

          def test_topic_specific_fiscal_year_rejection_returns_bounded_corrective_feedback
            @registry = ReadToolRegistry.new(definitions: [{ "name" => "read_reference", "description" => "Budget or gazette public read",
              "parameters" => { "type" => "object", "properties" => {
                "topic" => { "type" => "string", "maxLength" => 20, "enum" => %w(budget gazette) },
                "query" => { "type" => "string", "maxLength" => 160 },
                "fiscal_year" => { "type" => "integer", "minimum" => 1900, "maximum" => 2100 }
              }, "required" => ["topic"], "additionalProperties" => false },
              "handler" => lambda { |arguments:, context:|
                raise Contracts::Invalid, "Fiscal year only applies to budget" if arguments["topic"] == "gazette" && arguments.key?("fiscal_year")
                @reads << [arguments, context]
                @envelope
              } }])
            bad = { "name" => "read_reference", "args" => { "topic" => "gazette", "fiscal_year" => 2026 }, "id" => "call0" }
            good = { "name" => "read_reference", "args" => { "topic" => "gazette", "query" => "glasnik 2026" }, "id" => "call1" }
            native = ->(call) { OpenStruct.new(function_calls: [call], content: { "role" => "model", "parts" => [{ "functionCall" => call }] },
                                             finish_reason: "STOP", usage: { "promptTokenCount" => 10 }) }
            @responses = [native.call(bad), lambda {
              feedback = @requests.last.fetch(:contents).last.fetch("parts").first.fetch("functionResponse").fetch("response")
              assert_equal "invalid_topic_arguments", feedback.fetch("code")
              assert_includes feedback.fetch("explanation"), "query or date"
              native.call(good)
            }, -> { final }]
            result = runtime(execution_mode: "adaptive").call(message: "Službeni glasnik iz 2026?", context: @context)
            assert_equal "public", result.kind
            assert_equal 1, result.tool_calls
            assert_equal "glasnik 2026", @reads.first.first.fetch("query")
            assert_equal 1, @events.count { |event| event[:event] == "read_feedback" && event[:code] == "fiscal_year_scope" }
          end

          def test_revoked_evidence_is_not_softened_into_argument_feedback
            @registry = ReadToolRegistry.new(definitions: [{ "name" => "read", "description" => "Public read", "parameters" => @parameters,
              "handler" => lambda { |arguments:, context:| @reads << [arguments, context]; raise Contracts::Invalid, "Evidence no longer eligible" } }])
            @responses = [calls("read")]
            assert_equal "contract_failed", assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }.code
            assert_empty @events.select { |event| event[:event] == "read_feedback" }
          end

          def test_validated_read_observer_receives_public_read_before_later_composition_failure
            observed = []
            @responses = [calls("read"), -> { final(ids: [], text: "Unsupported") }]
            assert_raises(ModelLedConversation::Error) do
              runtime(validated_read_observer: ->(read:) { observed << read }).call(message: "Autobus do Janje?", context: @context)
            end
            assert_equal 1, observed.size
            assert_equal "read", observed.first.fetch("name")
            assert_equal "ok", observed.first.fetch("result_status")
            assert_equal ["r1"], observed.first.fetch("evidence_ids")
          end

          def test_two_calls_preserve_native_parts_and_ids_with_shared_budget_and_current_citations
            first = calls("read")
            @responses = [first, -> { final }]
            result = runtime.call(message: "Do Janje?", context: @context)
            assert_equal "public", result.kind
            assert_equal [2, 1], [result.model_calls, result.tool_calls]
            assert_same first.content, @requests.last[:contents][-2]
            assert_equal "call0", @requests.last[:contents].last["parts"].first["functionResponse"]["id"]
            assert_equal [[:planner, @budget], [:composer, @budget]], @phases
            assert_equal "NONE", @requests.last[:tool_mode]
            assert_empty @requests.last[:tools]
            refute @requests.last[:response_schema]["properties"]["evidence_ids"]["items"].has_key?("enum")
            refute_includes result.to_s, "Janja"
            refute_includes PP.pp(result, +""), "secret-signature"
            refute_includes @events.inspect, "Janja"
          end

          def test_multiple_native_reads_share_only_duplicate_handles_and_keep_canonical_outcomes
            original = JSON.generate(@envelope.for_prompt(context: @context, eligibility: ->(**) { true }))
            @responses = [calls("read", "read"), lambda {
              responses = @requests.last[:contents].last.fetch("parts").map { |part| part.fetch("functionResponse") }
              assert_equal(%w(call0 call1), responses.map { |part| part.fetch("id") })
              first_record = responses.first.fetch("response").fetch("evidence").first
              handle = first_record.fetch("id")
              refute_equal "r1", handle
              refute first_record.has_key?("document_id")
              duplicate = responses.last.fetch("response")
              assert_empty duplicate.fetch("evidence")
              assert_equal [handle], duplicate.fetch("previously_supplied_record_ids")
              final(ids: [handle])
            }]
            result = runtime.call(message: "Two independent public reads", context: @context)
            assert_equal ["r1"], result.answer.fetch("evidence_ids")
            assert_equal([["r1"], ["r1"]], result.executed_reads.map { |read| read.fetch("evidence_ids") })
            assert_equal [2, 2], [result.model_calls, result.tool_calls]
            assert_equal original, JSON.generate(@envelope.for_prompt(context: @context, eligibility: ->(**) { true }))
          end

          def test_current_candidate_handle_supports_clarification_but_never_an_answer
            @envelope = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "ambiguous", candidates: [
                                               { "id" => "candidate-canonical", "document_id" => "doc", "revision" => "v1", "label" => "Stop" }
                                             ])
            compose = lambda { |kind|
              id = @requests.last[:contents].last["parts"].first["functionResponse"]["response"]["candidates"].first["id"]
              final(kind:, ids: [id], text: "Koje stajalište?")
            }
            @responses = [calls("read"), -> { compose.call("answer") }]
            assert_raises(ModelLedConversation::Error) { runtime.call(message: "Stop", context: @context) }
            @responses = [calls("read"), -> { compose.call("clarification") }]
            result = runtime.call(message: "Stop", context: @context)
            assert_equal ["candidate-canonical"], result.answer.fetch("evidence_ids")
          end

          def test_worded_requested_clock_normalization_is_delivered_with_metadata_only_diagnostic
            @responses = [final(kind: "clarification", ids: [], text: "Poslije 06:00; sa kojeg stajališta?")]
            result = runtime.call(message: "Poslije šest ujutro?", context: @context)
            assert_equal "clarification", result.answer.fetch("kind")
            assert_equal 1, result.model_calls
            assert_equal([{ event: "answer_diagnostic", code: "unmatched_clock_literal", count: 1 }], @events.select { |event| event[:event] == "answer_diagnostic" })
            refute_includes @events.inspect, "06:00"
            refute_includes @events.inspect, "šest"
          end

          def test_clock_matching_is_not_misrepresented_as_semantic_validation_or_a_repair_trigger
            @responses = [calls("read"), -> { final(text: "Polazak 07:59.") }]
            result = runtime.call(message: "Janja", context: @context)
            assert_equal "Polazak 07:59.", result.answer.fetch("answer")
            assert_equal 2, result.model_calls
            assert_equal(1, @events.count { |event| event[:code] == "unmatched_clock_literal" })
            # This structurally accepted source-citing answer can still be wrong.
            # Its time/route relationship must be judged against the source in QA.
          end

          def test_provider_symbol_codes_remain_safe_metadata_without_exception_messages
            [:http_error, :deadline_exceeded, "invalid_structured_output", :"unsafe secret"].each do |code|
              error = StandardError.new("private provider message must not escape")
              error.define_singleton_method(:code) { code }
              @responses = [-> { raise error }]
              assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
              event = @events.reverse.find { |value| value[:event] == "phase_finished" }
              expected = code.to_s.match?(/\A[a-z][a-z0-9_]{0,63}\z/) ? code.to_s : "dependency_failed"
              assert_equal expected, event.fetch(:code)
              refute_includes @events.inspect, error.message
              refute_includes @events.inspect, "unsafe secret"
            end
          end

          def test_no_tool_clarification_finishes_first_call
            @responses = [final(kind: "clarification", ids: [], text: "Odakle putujete?")]
            result = runtime.call(message: "Do Janje?", context: @context)
            assert_equal 1, result.model_calls
            assert_empty @reads
            assert_empty result.frame.history, "Only the host may approve and persist public turn history"
            assert_equal "clarification", result.answer.fetch("kind")
          end

          def test_history_keeps_destination_but_current_correction_is_last_and_not_evidence
            frame = ConversationFrame.empty(context: @context).append(message: "Do Janje 16.9.2026.", answer: "Odakle?", context: @context,
                                                                      constraints: { "date" => "2026-09-16", "destination_id" => "janja" })
            @responses = [final(kind: "clarification", ids: [], text: "Koje polazište?")]
            runtime.call(message: "Ipak do Dvorova.", context: @context, frame: frame)
            assert_equal "Do Janje 16.9.2026.", @requests.first[:contents].first["parts"].first["text"]
            assert_equal "Ipak do Dvorova.", @requests.first[:contents].last["parts"].first["text"]
            assert_includes @requests.first[:system_instruction], "2026-09-16"
          end

          def test_protected_request_is_validated_but_never_executed_or_remembered
            @responses = [calls("private_status")]
            tool = { "name" => "private_status", "description" => "Propose authorized private read", "parameters" => @parameters }
            result = runtime(protected_tools: [tool]).call(message: "Moja prijava?", context: @context)
            assert_equal "protected", result.kind
            assert_equal "private_status", result.protected_request["name"]
            assert_empty result.frame.history
            assert_empty result.evidence
            assert_empty @reads
            assert_equal 1, @requests.size
          end

          def test_mixed_protected_and_public_calls_fail_before_any_read
            @responses = [calls("read", "private_status")]
            tool = { "name" => "private_status", "description" => "Private", "parameters" => @parameters }
            assert_equal "mixed_protected_request", assert_raises(ModelLedConversation::Error) { runtime(protected_tools: [tool]).call(message: "Prijava", context: @context) }.code
            assert_empty @reads
          end

          def test_revocation_during_composition_prevents_delivery
            @responses = [calls("read"), lambda {
              @eligible = false
              final
            }]
            assert_equal "contract_failed", assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }.code
          end

          def test_expired_generation_never_dispatches_tool
            @responses = [lambda {
              @clock = 8.8
              calls("read")
            }]
            assert_equal "deadline_exceeded", assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }.code
            assert_empty @reads
          end

          def test_no_third_generation_and_no_duplicate_read
            repeated = calls("read", "read")
            repeated.function_calls.last["args"] = repeated.function_calls.first["args"]
            @responses = [repeated, lambda {
              responses = @requests.last[:contents].last.fetch("parts").map { |part| part.fetch("functionResponse").fetch("response") }
              assert_equal "repeated_read", responses.last.fetch("code")
              assert_empty responses.last.fetch("evidence")
              final
            }]
            result = runtime.call(message: "Janja", context: @context)
            assert_equal 2, result.model_calls
            assert_equal 1, result.tool_calls
            assert_equal 1, @reads.size
            assert_includes @events.select { |event| event[:event] == "finalization_selected" }.map { |event| event[:reason] }, "repeated_call"
            @responses = [calls("read"), calls("read")]
            assert_equal "unexpected_final_tools", assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }.code
            assert_equal 4, @requests.size
          end

          def test_answer_cannot_cite_history_document_or_fact_ids
            @responses = [calls("read"), final(ids: ["nas"])]
            assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
            @responses = [final]
            assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
          end

          def test_stable_decoding_schema_keeps_current_citation_validation_strict
            [["unknown"], ["source"], [], %w(r1 r1)].each do |ids|
              @responses = [calls("read"), final(ids:)]
              assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
            end
            @envelope = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "ambiguous", evidence: [],
                                             candidates: [{ "id" => "c1", "document_id" => "source", "revision" => "v1", "label" => "Possible stop" }])
            @responses = [calls("read"), final(ids: ["c1"])]
            assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
          end

          def test_three_independent_reads_allowed_but_configured_ceiling_is_enforced_before_reads
            @responses = [calls("read", "read", "read"), -> { final }]
            result = runtime.call(message: "Tri javna izvora", context: @context)
            assert_equal 3, result.tool_calls
            @reads.clear
            @responses = [calls("read", "read", "read")]
            assert_equal "read_round_exceeded", assert_raises(ModelLedConversation::Error) { runtime(max_tool_calls: 2).call(message: "Tri izvora", context: @context) }.code
            assert_empty @reads
          end

          def test_tool_prose_is_not_delivered_and_authority_arguments_reject_without_read
            native = calls("read")
            native.content["parts"] << { "text" => "Already done" }
            @responses = [native, -> { final }]
            result = runtime.call(message: "Janja", context: @context)
            assert_same native.content, @requests.last[:contents][-2]
            assert_equal "Polazak je u 06:27.", result.answer.fetch("answer")
            refute_includes result.answer.fetch("answer"), "Already done"
            assert_equal 1, @reads.size
            @reads.clear
            native = calls("read")
            native.function_calls.first["args"]["actor_id"] = 2
            @responses = [native]
            assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
            assert_empty @reads
          end

          def test_argument_policy_validates_corrected_constraints_before_read
            @responses = [calls("read"), -> { final }]
            policy = lambda { |name:, context:, **|
              assert_equal "read", name
              assert_same @context, context
              { "query" => "corrected destination" }
            }
            runtime(argument_policy: policy).call(message: "Correction", context: @context)
            assert_equal "corrected destination", @reads.first.first["query"]
          end

          def test_provider_errors_do_not_expose_private_messages_or_causes
            @responses = [-> { raise StandardError, "private-error secret-signature" }]
            error = assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
            assert_equal "dependency_failed", error.message
            assert_nil error.cause
            refute_includes @events.inspect, "private-error"
          end

          def test_unsupported_url_is_rejected_and_schema_does_not_mutate_evidence
            @responses = [calls("read"), -> { final(text: "Idi na https://invented.invalid/") }]
            assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: @context) }
            public_value = @envelope.for_prompt(context: @context, eligibility: ->(**) { true })
            before = JSON.generate(public_value)
            contract = AnswerContract.new
            refute contract.schema(evidence: [public_value])["properties"]["evidence_ids"]["items"].has_key?("enum")
            contract.for_model(public_value)
            assert_equal before, JSON.generate(public_value)
            assert_equal %w(answer clarification limitation acknowledgment), contract.schema(evidence: [])["properties"]["kind"]["enum"]
          end

          def test_provider_finish_reason_and_nine_second_internal_ceiling
            response = final(kind: "clarification", ids: [], text: "Odakle?")
            response.finish_reason = "MAX_TOKENS"
            @responses = [response]
            context = @context.with(deadline: TurnBudget.new(timeout: 10))
            assert_equal "incomplete_generation", assert_raises(ModelLedConversation::Error) { runtime.call(message: "Janja", context: context) }.code
            assert_operator @requests.first[:deadline].remaining_seconds, :<=, 8.75
          end

          def test_large_eligible_evidence_keeps_envelope_limits_instead_of_legacy_snapshot_limits
            records = 41.times.map do |index|
              { "id" => "r#{index}", "document_id" => "source", "revision" => "v1", "text" => "Public fixture",
                "facts" => { "journey" => { "legs" => [{ "stop" => { "name" => "NAS" } }] } } }
            end
            @envelope = EvidenceEnvelope.new(organization_id: 1, registry_epoch: "r1", status: "ok", evidence: records)
            @responses = [calls("read"), -> { final(text: "Javno stajalište NAS.") }]
            result = runtime.call(message: "Janja", context: @context)
            assert_equal 41, result.evidence.first["evidence"].size
            assert_equal 41, result.executed_reads.first["evidence_ids"].size
          end

          def test_frames_drop_expiry_scope_and_unrecognized_private_fields
            frame = ConversationFrame.empty(context: @context).append(message: "Janja", answer: "Odakle?", context: @context)
            assert_empty ConversationFrame.load(frame.value, context: @context.with(actor_id: 3)).history
            assert_empty ConversationFrame.load(frame.value, context: @context.with(now: @context.now + 601)).history
            assert_nil ConversationFrame.normalize(frame.value.merge("draft" => "private"), now: @context.now)
            assert_nil ConversationFrame.normalize(frame.value.merge("constraints" => { "actor_id" => "2" }), now: @context.now)
            10.times { frame = frame.append(message: "j" * 1800, answer: "a" * 1800, context: @context) } # rubocop:disable Style/RedundantSelfAssignment -- immutable frame
            assert_operator JSON.generate(frame.value).bytesize, :<=, ConversationFrame::MAX_BYTES
            assert_operator frame.history.size, :<=, 4
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ContractsTest < Minitest::Test
          def payload
            {
              "action" => "report_problem", "topic" => "waste", "entities" => { "area_query" => +"Velika Obarska" },
              "operation" => "start", "needs_clarification" => false, "secondary" => nil, "locale" => "sr"
            }
          end

          def test_action_and_topic_are_separate_immutable_values
            input = payload
            result = Contracts::Understanding.parse(input)
            input["entities"]["area_query"].replace("Dvorovi")

            assert_equal "report_problem", result.action
            assert_equal "waste", result.topic
            assert_equal "Velika Obarska", result.entities.fetch("area_query")
            assert_raises(FrozenError) { result.entities["street"] = "Different" }
          end

          def test_authority_fields_are_never_accepted_from_model
            %w(organization_id actor_id account_state capabilities confirmed risk tool sql).each do |key|
              assert_raises(Contracts::Invalid) { Contracts::Understanding.parse(payload.merge(key => "untrusted")) }
              assert_raises(Contracts::Invalid) { Contracts::Understanding.parse(payload.merge("entities" => { key => "untrusted" })) }
            end
          end

          def test_wrong_types_unknown_enums_and_incomplete_payloads_fail_closed
            [nil, [], "{}", payload.except("operation"), payload.merge("action" => "execute_sql"),
             payload.merge("needs_clarification" => "false"), payload.merge("locale" => "invalid"),
             payload.merge("entities" => { "date" => [] }), payload.merge("entities" => { "area_query" => "a" * 161 })].each do |input|
              assert_raises(Contracts::Invalid) { Contracts::Understanding.parse(input) }
            end
          end

          def test_duplicate_symbol_string_keys_are_rejected
            assert_raises(Contracts::Invalid) { Contracts::Understanding.parse(payload.merge(action: "help")) }
          end

          def test_secondary_request_is_bounded_and_not_an_authority_channel
            second = { "action" => "registration", "topic" => "account" }
            result = Contracts::Understanding.parse(payload.merge("secondary" => second))

            assert_equal second, result.secondary
            assert_raises(Contracts::Invalid) do
              Contracts::Understanding.parse(payload.merge("secondary" => second.merge("confirmed" => true)))
            end
          end

          def test_change_area_requires_account_topic_for_primary_and_secondary_requests
            primary = Contracts::Understanding.parse(
              payload.merge("action" => "change_area", "topic" => "account")
            )
            secondary = Contracts::Understanding.parse(
              payload.merge("secondary" => { "action" => "change_area", "topic" => "account" })
            )

            assert_equal "change_area", primary.action
            assert_equal({ "action" => "change_area", "topic" => "account" }, secondary.secondary)
            assert_raises(Contracts::Invalid) do
              Contracts::Understanding.parse(payload.merge("action" => "change_area", "topic" => "neighborhood"))
            end
            assert_raises(Contracts::Invalid) do
              Contracts::Understanding.parse(
                payload.merge("secondary" => { "action" => "change_area", "topic" => "neighborhood" })
              )
            end
            assert_equal [nil, "unknown"], Contracts.action_topic!(nil, "unknown", allow_nil_action: true)
            assert_raises(Contracts::Invalid) { Contracts.action_topic!(nil, "unknown") }
          end

          def test_clarification_retains_script_without_enabling_effects
            result = Contracts::Understanding.clarify(locale: "sr-Cyrl")

            assert_equal "sr-Cyrl", result.locale
            assert_equal "help", result.action
            assert result.needs_clarification
            assert_empty result.entities
          end

          def test_trusted_scope_defaults_to_no_capabilities
            scope = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64)

            assert_equal "anonymous", scope.account_state
            refute scope.allows?(:write_report)
            refute scope.allows?(:write_neighborhood)
            assert_raises(Contracts::Invalid) { Contracts::TrustedContext.new(organization_id: nil, conversation_key: "a" * 64) }
            assert_raises(Contracts::Invalid) { Contracts::TrustedContext.new(organization_id: 1, conversation_key: "+387-personal-phone") }
            assert_raises(Contracts::Invalid) do
              Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, capabilities: ["arbitrary_write"])
            end
          end

          def test_read_results_distinguish_empty_unavailable_and_unauthorized
            %w(empty unavailable not_authorized stale unreviewed).each do |status|
              result = Contracts::ReadResult.new(status:)

              assert_equal status, result.status
              assert_nil result.checked_at
            end
            assert_raises(Contracts::Invalid) { Contracts::ReadResult.new(status: "unavailable", facts: [{ "claim" => "No outages" }]) }
            assert_raises(Contracts::Invalid) { Contracts::ReadResult.new(status: "ok", checked_at: "now") }
          end

          def test_read_result_copies_nested_facts_and_bounds_content
            facts = [{ "label" => +"Raspored", "days" => ["Monday"] }]
            result = Contracts::ReadResult.new(status: "ok", facts:, checked_at: Time.utc(2026, 9, 5))
            facts.first["label"].replace("Changed")

            assert_equal "Raspored", result.facts.first.fetch("label")
            assert_raises(FrozenError) { result.facts.first.fetch("days") << "Tuesday" }
            assert_raises(Contracts::Invalid) { Contracts::ReadResult.new(status: "ok", facts: Array.new(41) { {} }) }
            assert_raises(Contracts::Invalid) { Contracts.snapshot(Float::INFINITY) }
          end

          def test_handoff_defaults_are_an_offer_not_claimed_completion
            result = Contracts::HandoffResult.new(account_state: "anonymous", next_step: "registration_form", destination: "/users/sign_up")

            refute result.completed
            refute result.resume_supported
            assert_nil result.expires_at
            assert_raises(Contracts::Invalid) do
              Contracts::HandoffResult.new(account_state: "anonymous", next_step: "form", completed: "true")
            end
          end

          def test_directory_contact_topics_are_typed_ask_information_topics
            %w(health social_welfare agriculture permits education animals).each do |topic|
              assert_includes Contracts::TOPICS, topic
              result = Contracts::Understanding.parse(payload.merge("action" => "ask_information", "topic" => topic, "entities" => {}))

              assert_equal topic, result.topic
              assert_equal "ask_information", result.action
            end
            assert_equal Contracts::TOPICS.uniq, Contracts::TOPICS
          end

          def test_contract_retention_does_not_redefine_otp_lifetime
            assert_equal 1, Contracts::VERSION
            assert_equal 6, Contracts::MAX_TURNS
            assert_equal 1800, Contracts::CONTEXT_TTL
          end
        end
      end
    end
  end
end

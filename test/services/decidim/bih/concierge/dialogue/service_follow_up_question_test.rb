# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/service_follow_up_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ServiceFollowUpQuestionTest < Minitest::Test
          NOW = Time.utc(2026, 9, 10, 9)

          def test_contextual_contact_and_site_questions_work_in_both_scripts_and_english
            ["A koji je broj telefona službe?", "Који је њихов број телефона?", "A telefon?", "Kako da ih kontaktiram?",
             "What is their phone number?", "And the service phone number?", "How can I contact them?"].each do |text|
              assert_equal "contact", ServiceFollowUpQuestion.focus(text), text
            end
            ["A gdje je njihova stranica?", "А гдје је њихова страница?", "Koja je službena stranica?", "Gde mogu naći njihovu stranicu?",
             "Where is their website?", "What's their official website?"].each do |text|
              assert_equal "website", ServiceFollowUpQuestion.focus(text), text
            end
          end

          def test_named_new_requests_payment_private_contacts_negation_and_mixed_tasks_are_not_hijacked
            [nil, "", "a" * 161, "Koji je SMS broj?", "Broj za plaćanje", "Na koji broj šaljem poruku?",
             "Telefon Vodovoda", "Gdje je stranica Vodovoda?", "Privatni broj direktora", "Broj telefona komšije",
             "Ne treba mi njihov telefon", "A broj telefona službe i prijavi problem", "Their website and my account",
             "A njihov kontakt https://example.test/", "A broj telefona službe 0835501"].each do |text|
              assert_nil ServiceFollowUpQuestion.focus(text), text.inspect
            end
          end

          def test_only_one_matching_public_directory_identifier_is_retained
            original = state
            assert_equal "city_services:parking", retained(original)
            stale = state
            stale["prior_evidence"]["status"] = "stale"
            assert_equal "city_services:parking", retained(stale), "Unexpired ID may be reread; old status is not fresh authority"
            assert_equal original, state

            [original.merge("active_task" => "report_problem"), original.merge("topic" => "account"), original.merge("draft" => {}),
             original.merge("prior_evidence" => nil), original.merge("expires_at" => NOW.to_f - 1)].each { |value| assert_nil retained(value) }
            assert_nil ServiceFollowUpQuestion.retained_source_id(state: original, context: context(capabilities: []))
          end

          def test_expired_ambiguous_wrong_topic_private_and_url_bearing_evidence_are_rejected
            [->(value) { value["expires_at"] = NOW.to_f },
             ->(value) { value["topic"] = "water" },
             ->(value) { value["kind"] = "member_board" },
             ->(value) { value["facts"].first["source_id"] = "city_services:vodovod_servis" },
             ->(value) { value["facts"].first["id"] = "procedure:parking" },
             ->(value) { value["facts"].first["source_url"] = "https://example.test/" },
             ->(value) { value["facts"] << { "id" => "service:vodovod_servis", "source_id" => "city_services:vodovod_servis" } }].each do |change|
              value = state
              change.call(value.fetch("prior_evidence"))
              assert_nil retained(value)
            end
          end

          private

          def context(capabilities: ["public_reads"])
            Contracts::TrustedContext.new(organization_id: 71, conversation_key: "c" * 64, capabilities:, now: NOW)
          end

          def retained(value)
            ServiceFollowUpQuestion.retained_source_id(state: value, context: context)
          end

          def state
            { "active_task" => "ask_information", "topic" => "parking", "draft" => nil, "expires_at" => NOW.to_f + 600,
              "prior_evidence" => { "version" => 1, "kind" => "public_read", "action" => "ask_information", "topic" => "parking", "status" => "ok",
                                    "facts" => [{ "id" => "service:parking", "source_id" => "city_services:parking", "observed_at" => "2026-06-29" }],
                                    "scope" => { "area_slugs" => [] }, "expires_at" => NOW.to_f + 600 } }
          end
        end
      end
    end
  end
end

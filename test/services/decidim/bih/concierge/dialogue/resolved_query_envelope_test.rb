# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/evidence_envelope"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ResolvedQueryEnvelopeTest < Minitest::Test
          def envelope(query:, **scope)
            EvidenceEnvelope.new(organization_id: 1, registry_epoch: "epoch-1", status: "unsupported",
                                 query_scope: { "operation" => "plan_journey", "reason_code" => "unsupported_calendar",
                                                "search_complete" => false, "resolved_query" => query }.merge(scope))
          end

          def query
            { "version" => 1, "origin_ids" => ["transport-place:janja"], "destination_ids" => ["transport_stop:1"],
              "date" => "2026-09-17", "after_time" => "11:00", "timezone" => "Europe/Sarajevo", "mode" => "fastest",
              "direct_only" => false, "radius_meters" => 200, "transfer_limit" => 1,
              "origin_resolution" => "assumed_area", "destination_resolution" => "supplied_stop" }
          end

          def test_bounded_public_resolved_query_is_preserved
            scope = envelope(query: query).query_scope
            assert_equal query, scope.fetch("resolved_query")
            assert_equal "unsupported_calendar", scope.fetch("reason_code")
          end

          def test_private_coordinates_and_unknown_reasons_are_rejected
            assert_raises(Contracts::Invalid) { envelope(query: query.merge("latitude" => 44.756)) }
            assert_raises(Contracts::Invalid) { envelope(query: query, "reason_code" => "invented") }
          end

          def test_invalid_calendar_and_time_are_rejected
            assert_raises(Contracts::Invalid) { envelope(query: query.merge("date" => "2026-02-30")) }
            assert_raises(Contracts::Invalid) { envelope(query: query.merge("after_time" => "25:00")) }
          end
        end
      end
    end
  end
end

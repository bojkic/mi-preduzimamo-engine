# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "test_helper"
require "json"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/citation_projection"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class CitationProjectionTest < Minitest::Test
          def envelope(id = "canonical-leg")
            { "status" => "ok", "evidence" => [{ "id" => id, "document_id" => "document", "revision" => "rev",
                                                 "source_url" => "https://example.test/timetable", "text" => "Reviewed",
                                                 "facts" => { "stop_id" => "nas", "next_leg_id" => "leg2", "departure" => "06:27" },
                                                 "limitations" => ["School days"] }], "candidates" => [],
              "query_scope" => { "date" => "2026-09-16", "subject_ids" => ["nas"] }, "coverage_complete" => false }
          end

          def payload(ids)
            { "kind" => "answer", "answer" => "Public response", "evidence_ids" => ids }
          end

          def test_only_model_identity_changes_and_originals_remain_intact
            original = envelope
            before = JSON.generate(original)
            projection = CitationProjection.new
            projected = projection.for_model(original)
            record = projected.fetch("evidence").first
            assert_match(/\Ae[0-9a-f]{8}_1\z/, record.fetch("id"))
            refute record.has_key?("document_id")
            assert_equal(original.fetch("evidence").first.except("id", "document_id"), record.except("id"))
            assert_equal original.fetch("query_scope"), projected.fetch("query_scope")
            assert_equal before, JSON.generate(original)
            answer = payload([record.fetch("id")])
            assert_equal ["canonical-leg"], projection.canonical_payload(answer).fetch("evidence_ids")
            assert_equal [record.fetch("id")], answer.fetch("evidence_ids")
          end

          def test_wrapped_public_source_provenance_has_one_citation_identity_without_removing_domain_ids
            original = envelope
            source_fact = {
              "id" => "procedure:registry", "source_id" => "procedure:registry", "document_id" => "publisher-doc", "revision" => "reader-rev",
              "text" => "Documents have no administrative fee; postage amount is not published.",
              "source_url" => "https://example.test/registry", "source_label" => "Registry office",
              "reviewed_at" => "2026-09-09", "effective_from" => "2026-01-01", "effective_until" => nil,
              "warning_codes" => ["not_live_status"], "coverage" => { "geography" => "citywide", "complete_inventory" => false },
              "fee" => { "administrative_fee_bam" => 0, "postage_amount_bam" => nil },
              "source" => { "id" => "publisher", "source_id" => "publisher", "document_id" => "doc", "revision" => "v2",
                            "url" => "https://example.test/registry", "label" => "Public authority" },
              "journey" => { "origin_id" => "nas", "destination_id" => "janja", "legs" => [{ "id" => "leg1", "next_leg_id" => "leg2" }] }
            }
            original["evidence"][0]["facts"] = { "source_fact" => source_fact, "validity" => { "date" => "2026-09-16" },
                                                 "coverage" => { "matched_count" => 1, "complete_inventory" => false }, "origin_id" => "nas" }
            before = JSON.generate(original)
            projection = CitationProjection.new
            projected = projection.for_model(original)
            fact = projected["evidence"][0]["facts"]["source_fact"]
            expected = source_fact.except("id", "source_id", "document_id", "revision").merge(
              "source" => { "url" => "https://example.test/registry", "label" => "Public authority" }
            )
            assert_equal expected, fact
            assert_equal original["evidence"][0]["facts"].except("source_fact"), projected["evidence"][0]["facts"].except("source_fact")
            assert_equal before, JSON.generate(original)
            %w(procedure:registry publisher-doc reader-rev).each do |wrong_id|
              assert_raises(Contracts::Invalid) { projection.canonical_payload(payload([wrong_id])) }
            end
            handle = projected["evidence"][0]["id"]
            assert_equal ["canonical-leg"], projection.canonical_payload(payload([handle]))["evidence_ids"]
          end

          def test_unwrapped_transport_relationships_and_nested_domain_provenance_are_untouched
            original = envelope
            original["evidence"][0]["facts"].merge!("origin_id" => "nas", "destination_id" => "janja", "route_id" => "p12",
                                                    "legs" => [{ "id" => "leg1", "source_id" => "trip1", "next_leg_id" => "leg2" }])
            projected = CitationProjection.new.for_model(original)
            assert_equal original["evidence"][0]["facts"], projected["evidence"][0]["facts"]
          end

          def test_duplicate_canonical_records_share_handle_but_different_records_do_not
            projection = CitationProjection.new
            first = projection.for_model(envelope).fetch("evidence").first.fetch("id")
            assert_equal first, projection.for_model(envelope).fetch("evidence").first.fetch("id")
            second = projection.for_model(envelope("other-leg")).fetch("evidence").first.fetch("id")
            refute_equal first, second
            assert_equal %w(canonical-leg other-leg), projection.canonical_payload(payload([first, second])).fetch("evidence_ids")
            changed = envelope
            changed["evidence"][0]["facts"]["departure"] = "09:00"
            assert_raises(Contracts::Invalid) { projection.for_model(changed) }
          end

          def test_unknown_document_canonical_and_previous_turn_handles_are_rejected
            first_turn = CitationProjection.new
            stale = first_turn.for_model(envelope).fetch("evidence").first.fetch("id")
            next_turn = CitationProjection.new
            next_turn.for_model(envelope("different-current-leg"))
            [stale, "document", "canonical-leg", "unknown", nil].each do |id|
              assert_raises(Contracts::Invalid) { next_turn.canonical_payload(payload([id])) }
            end
            assert_raises(Contracts::Invalid) { next_turn.canonical_payload(payload(Array.new(41, stale))) }
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/claim_contract"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class ClaimContractTest < Minitest::Test
          def setup
            @contract = ClaimContract.new
            @record = { "id" => "r1", "document_id" => "public:route", "revision" => "v1", "text" => "Public trip" }
            @evidence = [{ "status" => "ok", "coverage_complete" => false, "evidence" => [@record], "query_scope" => { "operation" => "plan_journey" } }]
          end

          def test_current_cited_record_is_a_structural_selection_only
            value = @contract.call(selections: [{ "kind" => "selected_journey", "evidence_id" => "r1" }], cited_ids: ["r1"], evidence: @evidence)
            assert_equal "selected_journey", value.first.fetch("kind")
            assert value.frozen?
            assert_equal "last_departure", @contract.call(selections: [{ "kind" => "last_departure", "evidence_id" => "r1" }],
                                                           cited_ids: ["r1"], evidence: @evidence).first.fetch("kind")
          end

          def test_uncited_and_absent_records_cannot_be_selected
            [{ "kind" => "selected_journey", "evidence_id" => "r1" },
             { "kind" => "selected_journey", "evidence_id" => "old" }].each do |selection|
              assert_raises(Contracts::Invalid) { @contract.call(selections: [selection], cited_ids: [], evidence: @evidence) }
            end
          end

          def test_scoped_zero_result_requires_complete_covered_empty_envelope
            claim = { "kind" => "scoped_no_match" }
            assert_raises(Contracts::Invalid) { @contract.call(selections: [claim], cited_ids: [], evidence: @evidence) }
            empty = [{ "status" => "empty", "coverage_complete" => true, "evidence" => [],
                       "query_scope" => { "operation" => "plan_journey" } }]
            assert_equal [claim], @contract.call(selections: [claim], cited_ids: [], evidence: empty)
          end
        end
      end
    end
  end
end

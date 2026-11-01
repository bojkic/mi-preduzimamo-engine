# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/answer_contract"

class AnswerContractSchemaTest < Minitest::Test
  def test_generation_schema_is_stable_bounded_and_does_not_copy_record_ids
    contract = Decidim::Bih::Concierge::Dialogue::AnswerContract.new
    expected = contract.schema
    [0, 1, 2, 41].each do |count|
      records = count.times.map { |index| { "id" => "transport-leg:#{index.to_s.rjust(64, "0")}" } }
      evidence = [{ "evidence" => records, "candidates" => [] }]
      schema = contract.schema(evidence:)
      assert_equal expected, schema
      assert_equal 40, schema.dig("properties", "evidence_ids", "maxItems")
      refute schema.dig("properties", "evidence_ids", "items").has_key?("enum")
      assert_equal records, evidence.first.fetch("evidence")
    end
  end

  def test_returned_schema_mutation_does_not_change_the_contract
    contract = Decidim::Bih::Concierge::Dialogue::AnswerContract.new
    schema = contract.schema
    schema["properties"]["evidence_ids"]["maxItems"] = 900
    assert_equal 40, contract.schema.dig("properties", "evidence_ids", "maxItems")
  end
end

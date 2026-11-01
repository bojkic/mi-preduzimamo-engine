# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class AiCaseUsageTest < ActiveSupport::TestCase
        setup { CaseUsageDay.delete_all }
        test "unverified models fail closed" do
          error = assert_raises(Ai::CaseUsage::Refused) { Ai::CaseUsage.new.reserve!(model: 'unknown', purpose: 'primary', input_tokens: 100, output_tokens: 100) }
          assert_equal 'unverified_or_unpriced_model', error.message
          assert_empty CaseUsageDay.all
        end
        test "every call type uses the same conservative daily reservation" do
          usage = Ai::CaseUsage.new(prices: { 'fixture' => { verified: true, input: 1, output: 1 } }, cap: '0.0008')
          %w(primary check repair attachment).each { |purpose| usage.reserve!(model: 'fixture', purpose:, input_tokens: 100, output_tokens: 100) }
          assert_equal BigDecimal('0.0008'), CaseUsageDay.last.reserved_usd
          assert_raises(Ai::CaseUsage::Refused) { usage.reserve!(model: 'fixture', purpose: 'repair', input_tokens: 1, output_tokens: 1) }
        end
        test "only the fixed bounded probe bypasses access verification and reserves from the ordinary cap" do
          client = Object.new
          def client.generate_content(**options)
            raise 'unexpected retry' unless options[:retry_once] == false
            raise 'unbounded output' unless options.dig(:generation_limits, :max_output_tokens) == 256
            raise 'probe thinking enabled' unless options.dig(:generation_limits, :thinking_budget) == 0
            raise 'arbitrary probe prompt' unless options[:contents] == [{ role: 'user', parts: [{ text: 'Return {"ok":true}.' }] }]
            { 'ok' => true }
          end
          usage = Ai::CaseUsage.new(prices: { 'fixture' => { verified: true, input: 1, output: 1, requires_access_receipt: true } })
          Config.stub(:report_case_model_access_verified?, false) do
            assert_raises(Ai::CaseUsage::Refused) { usage.reserve!(model: 'fixture', purpose: 'primary', input_tokens: 100, output_tokens: 32) }
            assert_equal({ 'ok' => true }, usage.probe(client:, model: 'fixture'))
            assert_operator CaseUsageDay.last.reserved_usd, :>, 0
            assert_raises(Ai::CaseUsage::Refused) do
              usage.call(client:, model: 'fixture', purpose: 'access_probe', contents: [{ text: 'Arbitrary case text' }], generation_limits: { max_output_tokens: 32, candidate_count: 1 })
            end
          end
        end
        test "a probe timeout retains its conservative reservation" do
          client = Object.new
          def client.generate_content(**options)
            raise 'unexpected retry' unless options[:retry_once] == false
            raise Timeout::Error
          end
          usage = Ai::CaseUsage.new(prices: { 'fixture' => { verified: true, input: 1, output: 1, requires_access_receipt: true } })
          Config.stub(:report_case_model_access_verified?, false) do
            assert_raises(Timeout::Error) { usage.probe(client:, model: 'fixture') }
          end
          assert_equal usage.reserved_usd_total, CaseUsageDay.last.reserved_usd
          assert_operator usage.reserved_usd_total, :>, 0
        end
        test "timeout is charged and not retried invisibly" do
          client = Object.new
          def client.generate_content(**options)
            raise 'must not retry' if options[:retry_once]
            raise Timeout::Error
          end
          usage = Ai::CaseUsage.new(prices: { 'fixture' => { verified: true, input: 1, output: 1 } })
          assert_raises(Timeout::Error) do
            usage.call(client:, model: 'fixture', purpose: 'primary', contents: [{ text: 'input' }], generation_limits: { max_output_tokens: 100, candidate_count: 1 })
          end
          assert_operator CaseUsageDay.last.reserved_usd, :>, 0
        end
      end
    end
  end
end

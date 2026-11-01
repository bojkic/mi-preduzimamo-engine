# frozen_string_literal: true
require 'test_helper'
require 'timeout'
module Decidim
  module Bih
    module RailsHarness
      class AiCaseUsageConcurrencyTest < ActiveSupport::TestCase
        self.use_transactional_tests = false
        test 'independent concurrent reservations never exceed the shared daily cap' do
          travel_to Time.utc(2099, 4, 9)
          day = Time.current.utc.to_date
          CaseUsageDay.where(day:).delete_all
          ready, start = Queue.new, Queue.new
          threads = 2.times.map do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                usage = Ai::CaseUsage.new(prices: { 'fixture' => { verified: true, input: 1, output: 1 } }, cap: '0.0002')
                ready << true
                start.pop
                begin
                  usage.reserve!(model: 'fixture', purpose: 'primary', input_tokens: 100, output_tokens: 100)
                  :reserved
                rescue Ai::CaseUsage::Refused
                  :refused
                end
              end
            end
          end
          Timeout.timeout(15) { 2.times { ready.pop }; 2.times { start << true } }
          values = Timeout.timeout(15) { threads.map(&:value) }
          assert_equal [:refused, :reserved], values.sort
          assert_equal BigDecimal('0.0002'), CaseUsageDay.find_by!(day:).reserved_usd
        ensure
          threads&.each { |thread| thread.kill if thread.alive? }
          threads&.each(&:join)
          CaseUsageDay.where(day:).delete_all if day
          travel_back
        end
      end
    end
  end
end

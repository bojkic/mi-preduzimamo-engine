# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/goodwill/monthly_statement"

module Decidim
  module Bih
    module Goodwill
      class MonthlyStatementTest < Minitest::Test
        Account = Struct.new(:id) do
          def persisted? = !id.nil?
        end

        def test_missing_or_unsaved_wallet_does_not_query_financial_history
          [nil, Account.new(nil)].each do |account|
            assert_equal [], MonthlyStatement.new(account).months
          end
        end
        # SQL month boundaries, source corrections, opposite-direction gifts and
        # refund handling: rails_test/goodwill_monitoring_and_statement_test.rb.
      end
    end
  end
end

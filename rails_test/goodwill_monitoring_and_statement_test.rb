# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class GoodwillMonitoringAndStatementTest < ActiveSupport::TestCase
        G = Decidim::Bih::Goodwill

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @ledger = G::Ledger.new
        end

        test "monitoring distinguishes a failed read from a complete empty review without leaking exception text" do
          assert_equal "complete", G::MonitoringSnapshot.new(@organization).call.fetch(:status)
          failure = ->(*) { raise ActiveRecord::StatementInvalid, "private synthetic failure context" }
          messages = []
          Rails.logger.stub(:error, ->(message) { messages << message }) do
            G::Referral.stub(:where, failure) do
              result = G::MonitoringSnapshot.new(@organization).call
              assert_equal "failed", result.fetch(:status)
              assert_not result.key?(:rejected_reports), "failure must not masquerade as zero findings"
              assert result.fetch(:computed_at)
            end
          end
          assert_includes messages.join, "status=failed"
          assert_not_includes messages.join, "private synthetic failure context"
        end

        test "monitoring uses actual report event foreign key and distinguishes duplicate from explicit rejection" do
          main = Report.create!(organization: @organization, author: @user, status: "primljeno", description: "Main problem")
          duplicate = Report.create!(organization: @organization, author: @other, status: "odbijeno",
            duplicate_of: main, description: "Duplicate problem")
          duplicate.record_event!("case_decision_applied", actor: @admin, metadata: { action: "duplicate" })
          rejected = Report.create!(organization: @organization, author: @other, status: "odbijeno",
            duplicate_of: main, description: "Rejected problem")
          rejected.record_event!("case_decision_applied", actor: @admin, metadata: { action: "reject" })
          result = G::MonitoringSnapshot.new(@organization).call
          assert_equal "complete", result.fetch(:status)
          assert_equal 1, result.fetch(:duplicate_reports)
          assert_equal 1, result.fetch(:rejected_reports)
        end

        test "a referral cycle is bounded and marks the graph review partial" do
          G::Referral.create!(organization: @organization, referrer: @user, invitee: @other)
          G::Referral.create!(organization: @organization, referrer: @other, invitee: @user)
          result = G::MonitoringSnapshot.new(@organization).call
          assert_equal "partial", result.fetch(:status)
          assert result.fetch(:referral_graph_truncated)
          assert_operator result.fetch(:observed_referral_depth), :<=, 100
        end

        test "monthly statement preserves opposite gift flows refund direction and Sarajevo month boundary" do
          travel_to Time.utc(2026, 4, 30, 22, 30) do
            @ledger.award(@user, 100, reason: "manual_test")
            @ledger.transfer(from_owner: @user, to_owner: @other, amount: 40, kind: "gift")
            @ledger.transfer(from_owner: @other, to_owner: @user, amount: 20, kind: "gift")
            spent = @ledger.spend(owner: @user, amount: 30, kind: "redeem")
            @ledger.reverse(spent, actor: @admin)
          end
          account = @ledger.account_for(@user)
          row = G::MonthlyStatement.new(account).months.sole
          assert_equal Date.new(2026, 5, 1), row.fetch(:month)
          assert_equal 100, row.fetch(:earned)
          assert_equal(-30, row.fetch(:spent))
          assert_equal({ "earned" => 100, "given" => -40, "received" => 20, "spent" => -30, "refunds" => 30 }, row.fetch(:by_category))
          assert_equal 80, row.fetch(:net)
          assert_equal account.reload.balance, row.fetch(:running_balance)
        end

        test "recognition correction belongs to the earning month and recovery belongs to its posting month" do
          original = nil
          travel_to Time.utc(2026, 4, 30, 22, 30) do
            original = @ledger.award(@user, 100, reason: "manual_test")
          end
          travel_to Time.utc(2026, 6, 2, 10) do
            @ledger.award(@user, 30, reason: "manual_test")
            G::SourceCreditCorrection.revoke(original, actor: @admin)
          end
          account = @ledger.account_for(@user)
          rows = G::MonthlyStatement.new(account).months
          assert_equal [Date.new(2026, 6, 1), Date.new(2026, 5, 1)], rows.map { |row| row[:month] }
          assert_equal [0, -100], rows.map { |row| row[:recognition_adjustment] }
          assert_equal [-70, 100], rows.map { |row| row[:net] }
          assert_equal [30, 100], rows.map { |row| row[:running_balance] }
          assert_equal account.reload.balance, rows.first.fetch(:running_balance)
        end
      end
    end
  end
end

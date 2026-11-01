# frozen_string_literal: true
require "test_helper"
require "timeout"
require "decidim/proposals/test/factories"
module Decidim
  module Bih
    module RailsHarness
      # Independent committed connections are required to exercise advisory locks.
      # Every case has a fresh tenant in the isolated disposable harness database.
      class GoodwillAccountingConcurrencyTest < ActiveSupport::TestCase
        self.use_transactional_tests = false
        G = Decidim::Bih::Goodwill
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @ledger = G::Ledger.new
          @account = @ledger.account_for(@user)
        end

        def simultaneously(*actions)
          ready = Queue.new
          start = Queue.new
          errors = Queue.new
          threads = actions.map do |action|
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                ready << true
                start.pop
                action.call
              end
            rescue StandardError => error
              errors << error
            end
          end
          Timeout.timeout(15) do
            actions.length.times { ready.pop }
            actions.length.times { start << true }
            threads.each(&:join)
          end
          raise errors.pop unless errors.empty?
        ensure
          threads&.each { |thread| thread.kill if thread.alive? }
        end

        test "spending and source correction cannot overdraw or corrupt recognized contribution" do
          source = Report.create!(organization: @organization, author: @user, description: "Street light", status: "primljeno")
          G::EarningRules.new.award(@user, :report, idempotency_key: G::IdempotencyKey.report(source.id))
          source.update!(status: "odbijeno")
          source.record_event!("case_decision_applied", actor: @admin, metadata: { action: "reject" })
          simultaneously(
            -> { G::SourceCreditCorrection.call(report: Report.find(source.id)) },
            -> do
              G::Ledger.new.spend(owner: Decidim::User.find(@user.id), amount: 15, kind: "redeem", idempotency_key: "concurrent-spend")
            rescue G::InsufficientBalanceError
              nil
            end
          )
          assert_operator @account.reload.balance, :>=, 0
          assert_equal 0, @account.contribution_score
          assert_equal @account.recomputed_balance, @account.balance
          assert_equal @account.recomputed_contribution, @account.contribution_score
          assert_equal 1, G::CreditCorrection.where(account: @account).count
        end

        test "opposite transfers use one deterministic account lock order" do
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(@user, 100, reason: "manual")
          @ledger.award(other, 100, reason: "manual")
          simultaneously(
            -> { G::Ledger.new.transfer(from_owner: @user, to_owner: other, amount: 10, kind: "gift", idempotency_key: "left") },
            -> { G::Ledger.new.transfer(from_owner: other, to_owner: @user, amount: 15, kind: "gift", idempotency_key: "right") }
          )
          assert_equal 105, @account.reload.balance
          assert_equal 95, @ledger.account_for(other).reload.balance
        end

        test "concurrent proposal workers pay the earliest published source only" do
          component = FactoryBot.create(:proposal_component, organization: @organization)
          first = FactoryBot.create(:proposal, component:, users: [@user], published_at: 2.hours.ago)
          later = FactoryBot.create(:proposal, component:, users: [@user], published_at: 1.hour.ago)
          simultaneously(*[later, first].map do |proposal|
            -> { G::EarningRules.new.award(Decidim::User.find(@user.id), :proposal,
              idempotency_key: G::IdempotencyKey.proposal(proposal.id, @user.id)) }
          end)
          assert_equal 25, @account.reload.contribution_score
          assert G::Transaction.exists?(organization: @organization, idempotency_key: G::IdempotencyKey.proposal(first.id, @user.id))
          refute G::Transaction.exists?(organization: @organization, idempotency_key: G::IdempotencyKey.proposal(later.id, @user.id))
        end

        test "stale handover cannot reopen a refund committed under the fulfillment lock" do
          @ledger.award(@user, 100, reason: "manual")
          transaction = @ledger.spend(owner: @user, amount: 20, kind: "redeem", reason: "reward")
          fulfillment = G::RewardFulfillment.create!(organization: @organization, user: @user,
            ledger_transaction: transaction, reward_key: "test", cost: 20, status: "requested")
          stale = G::RewardFulfillment.find(fulfillment.id)
          @ledger.reverse(transaction, actor: @admin)
          refute stale.mark!("fulfilled", by: @admin)
          assert_equal "reversed", fulfillment.reload.status
          assert_equal 100, @account.reload.balance
          assert_equal 100, @account.contribution_score
        end

        test "two distinct corroborations consume one shared daily allowance without duplicate credits" do
          main = Report.create!(organization: @organization, author: @admin, description: "Street light", status: "primljeno")
          simultaneously(*2.times.map { -> { G::CorroborateReport.call(report: Report.find(main.id), user: Decidim::User.find(@user.id)) } })
          assert_equal 1, ReportCorroboration.where(organization: @organization, user: @user).count
          assert_equal 5, @account.reload.balance
          assert_equal 1, G::AwardAdmission.where(account: @account, outcome: "awarded").count
        end
      end
    end
  end
end

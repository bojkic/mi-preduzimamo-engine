# frozen_string_literal: true
require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class HistoricalReportRepairTest < ActiveSupport::TestCase
        G = Decidim::Bih::Goodwill
        setup do
          travel_to Time.utc(2026, 9, 27, 12)
          @organization = create_organization
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @users = 2.times.map { FactoryBot.create(:user, :confirmed, organization: @organization) }
          @ledger = G::Ledger.new
          @reports = @users.map do |user|
            report = Report.create!(organization: @organization, author: user, description: "Historical source", status: "primljeno", anonymous: true, created_at: 30.days.ago)
            @ledger.award(user, 20, reason: "report", idempotency_key: G::IdempotencyKey.report(report.id), metadata: { occurred_at: report.created_at.iso8601 })
            report.update_columns(status: "odbijeno")
            report
          end
          @repair = G::HistoricalReportRepair.new(organization: @organization)
          @manifest = @repair.preview(report_ids: @reports.map(&:id))
        end
        teardown { travel_back }
        def apply(manifest = @manifest)
          @repair.apply!(manifest:, actor: @admin, expected_digest: manifest.fetch("digest"),
                         expected_summary: { reports: 2, users: 2, recognition_delta: -40 })
        end

        test "bounded repair reconciles originals and replays without new journals or wallet entries" do
          assert_difference("Decidim::Bih::Goodwill::CreditCorrection.count", 2) { assert_equal(-40, apply[:recognition_delta]) }
          assert @users.all? { |user| @ledger.account_for(user).reload.balance.zero? && @ledger.account_for(user).contribution_score.zero? }
          assert G::Transaction.where(organization: @organization, kind: "earn").all? { |tx| tx.credited_amount == 20 }
          assert_no_difference(["Decidim::Bih::Goodwill::CreditCorrection.count", "Decidim::Bih::Goodwill::Transaction.count"]) do
            assert apply[:replay]
          end
          assert G::Transaction.where(organization: @organization).all? { |tx| tx.entries.sum(:amount).zero? }
        end

        test "stale source anywhere aborts before the first correction" do
          @reports.last.update_columns(status: "primljeno")
          assert_no_difference("Decidim::Bih::Goodwill::CreditCorrection.count") do
            assert_raises(G::HistoricalReportRepair::Invalid) { apply }
          end
          assert @users.all? { |user| @ledger.account_for(user).reload.balance == 20 }
        end

        test "concurrent spend and digest tampering cannot bypass reviewed wallet impact" do
          @ledger.spend(owner: @users.last, amount: 5, kind: "redeem")
          assert_no_difference("Decidim::Bih::Goodwill::CreditCorrection.count") do
            assert_raises(G::HistoricalReportRepair::Invalid) { apply }
          end
          tampered = @manifest.deep_dup
          tampered["rows"].first["target_amount"] = 10
          assert_raises(G::HistoricalReportRepair::Invalid) { apply(tampered) }
        end

        test "failed second correction rolls back every earlier journal and wallet delta" do
          original = G::SourceCreditCorrection.method(:call)
          counter = 0
          failing = lambda do |**args|
            counter += 1
            raise G::HistoricalReportRepair::Invalid, "simulated failure" if counter == 2
            original.call(**args)
          end
          G::SourceCreditCorrection.stub(:call, failing) do
            assert_no_difference(["Decidim::Bih::Goodwill::CreditCorrection.count", "Decidim::Bih::Goodwill::Transaction.count"]) do
              assert_raises(G::HistoricalReportRepair::Invalid) { apply }
            end
          end
          assert @users.all? { |user| @ledger.account_for(user).reload.balance == 20 }
        end

        test "insufficient wallet records pending recovery while recognition is corrected" do
          @ledger.spend(owner: @users.last, amount: 15, kind: "redeem")
          @manifest = @repair.preview(report_ids: @reports.map(&:id))
          assert_equal 1, @manifest.fetch("summary").fetch("admin_pending")
          assert_equal(-20, @manifest.fetch("summary").fetch("wallet_delta"))
          assert_equal 1, apply[:admin_pending]
          assert_equal 5, @ledger.account_for(@users.last).reload.balance
          assert_equal 0, @ledger.account_for(@users.last).contribution_score
        end

        test "ordinary anonymous report is excluded from correction scope" do
          @reports.first.update_columns(status: "primljeno")
          assert_raises(G::HistoricalReportRepair::Invalid) { @repair.preview(report_ids: [@reports.first.id]) }
        end
      end
    end
  end
end

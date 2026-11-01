# frozen_string_literal: true
require "test_helper"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module RailsHarness
      class GoodwillSourceAccountingTest < ActiveSupport::TestCase
        G = Decidim::Bih::Goodwill
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @ledger = G::Ledger.new
          @account = @ledger.account_for(@user)
          @rules = G::EarningRules.new(organization: @organization)
          Setting.put(@organization, G::EarningRules::POLICY_NAMESPACE, "report_problem_effective_at", 1.day.ago.iso8601)
          Setting.put(@organization, G::EarningRules::POLICY_NAMESPACE, "monthly_proposal_effective_at", "2026-09-01T00:00:00+02:00")
        end

        def report(author: @user, anonymous: false, created_at: Time.current)
          Report.create!(organization: @organization, author:, anonymous:, description: "Broken street light", status: "primljeno", created_at:)
        end

        def earn_report(record)
          @rules.award(record.author, :report, idempotency_key: G::IdempotencyKey.report(record.id))
        end

        def decide(record, status:, action:, duplicate_of: nil)
          record.update!(status:, duplicate_of:)
          record.record_event!("case_decision_applied", actor: @admin, metadata: { action: })
          G::SourceCreditCorrection.call(report: record, actor: @admin)
        end

        test "outcomes append target deltas with source-period recognition and safe replay" do
          original_time = 35.days.ago
          source = report(anonymous: true, created_at: original_time)
          original = earn_report(source)
          main = report(author: FactoryBot.create(:user, :confirmed, organization: @organization))
          correction = decide(source, status: "odbijeno", action: "duplicate", duplicate_of: main)
          assert_equal [-15, 5, "settled"], [correction.recognition_delta, correction.target_amount, correction.settlement.status]
          assert_equal [5, 5, 5], [@account.reload.balance, @account.contribution_score, @account.recomputed_contribution]
          assert_equal 0, G::ContributionProjection.score(@account, since: 1.day.ago)
          assert_equal 5, G::ContributionProjection.score(@account, since: 40.days.ago)
          assert_no_difference -> { G::CreditCorrection.count } do
            assert_equal correction.id, G::SourceCreditCorrection.call(report: source).id
          end
          rejected = decide(source, status: "odbijeno", action: "reject", duplicate_of: main)
          assert_equal(-5, rejected.recognition_delta, "explicit rejection overrides the stale duplicate link")
          assert_equal 0, @account.reload.contribution_score
          restored = decide(source, status: "primljeno", action: "reopen")
          assert_equal 20, restored.recognition_delta
          assert_equal [20, 20], [@account.reload.balance, @account.contribution_score]
          assert_equal 20, original.reload.credited_amount
          assert G::Transaction.where(organization: @organization).all? { |transaction| transaction.entries.sum(:amount).zero? }
        end

        test "insufficient wallet corrects recognition immediately and never collects future earnings automatically" do
          source = report
          earn_report(source)
          @ledger.spend(owner: @user, amount: 15, kind: "redeem", idempotency_key: "spend")
          correction = decide(source, status: "odbijeno", action: "reject")
          assert_equal "admin_pending", correction.settlement.status
          assert_equal [5, 0], [@account.reload.balance, @account.contribution_score]
          @ledger.award(@user, 30, reason: "manual", idempotency_key: "later-earn")
          source.record_event!("case_decision_applied", actor: @admin, metadata: { action: "reject" })
          next_version = G::SourceCreditCorrection.call(report: source)
          assert_equal "superseded", correction.settlement.reload.status
          assert_equal "admin_pending", next_version.settlement.status
          assert_equal 35, @account.reload.balance
          G::SourceCreditCorrection.settle!(next_version, actor: @admin)
          assert_equal [15, 30], [@account.reload.balance, @account.contribution_score]
          assert_no_difference -> { G::Transaction.count } do
            G::SourceCreditCorrection.settle!(next_version, actor: @admin)
          end
        end

        test "restoration cancels an obsolete pending deduction without minting money" do
          source = report
          earn_report(source)
          @ledger.spend(owner: @user, amount: 20, kind: "redeem")
          old = decide(source, status: "odbijeno", action: "reject")
          restored = decide(source, status: "primljeno", action: "reopen")
          assert_equal "superseded", old.settlement.reload.status
          assert_equal "settled", restored.settlement.status
          assert_equal 0, restored.settlement.wallet_delta
          assert_equal [0, 20], [@account.reload.balance, @account.contribution_score]
          assert_raises(G::SourceCreditCorrection::StaleDecision) { G::SourceCreditCorrection.settle!(old, actor: @admin) }
        end

        test "source preview version rejects changed moderation and unrelated actors" do
          source = report
          earn_report(source)
          preview = G::SourceCreditCorrection.preview(report: source)
          decide(source, status: "odbijeno", action: "reject")
          assert_raises(G::SourceCreditCorrection::StaleDecision) do
            G::SourceCreditCorrection.call(report: source, expected_version: preview[:decision_version])
          end
          outsider = FactoryBot.create(:user, :admin, :confirmed, organization: create_organization)
          correction = G::CreditCorrection.order(:id).last
          assert_raises(Decidim::ActionForbidden) { G::SourceCreditCorrection.settle!(correction, actor: outsider) }
        end

        test "a cap-denied report never acquires an entitlement from later moderation" do
          5.times { earn_report(report) }
          denied = report
          assert_nil earn_report(denied)
          admission = G::AwardAdmission.find_by!(source_key: G::IdempotencyKey.report(denied.id))
          assert_equal "capped", admission.outcome
          decide(denied, status: "odbijeno", action: "reject")
          decide(denied, status: "primljeno", action: "reopen")
          assert_nil earn_report(denied)
          assert_equal 100, @account.reload.contribution_score
        end

        test "disabling report awards also disables duplicate and corroboration payments" do
          Setting.put(@organization, G::EarningRules::SCHEDULE_NAMESPACE, "report", 0)
          main = report(author: @admin)
          ordinary = report
          duplicate = report
          duplicate.update!(status: "odbijeno", duplicate_of: main)
          duplicate.record_event!("case_decision_applied", actor: @admin, metadata: { action: "duplicate" })
          assert_equal 0, G::ReportEntitlement.outcome_target(ordinary)
          assert_equal 0, G::ReportEntitlement.outcome_target(duplicate)
          assert_nil earn_report(ordinary)
          assert_nil earn_report(duplicate)
          assert_nil G::CorroborateReport.call(report: main, user: @user).transaction
          assert_equal 0, @account.reload.balance
          assert_equal 0, @account.contribution_score
          assert_equal 3, G::AwardAdmission.where(account: @account, action: "report", amount: 0).count
          assert_equal 0, G::AwardAdmission.awarded.where(account: @account, action: "report").count
        end

        test "corroboration and duplicate report share one actor problem entitlement including own reports" do
          main = report(author: @admin)
          result = G::CorroborateReport.call(report: main, user: @user)
          assert_equal 5, result.transaction.credited_amount
          assert_equal "replayed", G::CorroborateReport.call(report: main, user: @user).outcome
          duplicate = report
          duplicate.update!(status: "odbijeno", duplicate_of: main)
          duplicate.record_event!("case_decision_applied", actor: @admin, metadata: { action: "duplicate" })
          assert_nil earn_report(duplicate)
          assert_equal 5, @account.reload.contribution_score
          own = report
          earn_report(own)
          assert_nil G::CorroborateReport.call(report: own, user: @user).transaction
          assert_equal 25, @account.reload.contribution_score
        end

        test "merge and rejection of the main problem correct dependent sources once" do
          main = report(author: @admin)
          corroboration = G::CorroborateReport.call(report: main, user: @user).corroboration
          main.update!(status: "odbijeno")
          main.record_event!("case_decision_applied", actor: @admin, metadata: { action: "reject" })
          intent = G::CorrectionIntent.where(report: main).order(:id).last
          G::SourceCreditCorrectionJob.perform_now(intent.id)
          assert_equal 0, @account.reload.contribution_score
          assert_equal 0, G::SourceCreditCorrection.recognized_total(G::Transaction.find_by!(idempotency_key: "report-corroboration:#{corroboration.id}"))
          assert_no_difference(-> { G::CreditCorrection.count }) { G::SourceCreditCorrectionJob.perform_now(intent.id) }
        end

        test "historical duplicate awards stay five while seeding the new entitlement" do
          Setting.put(@organization, G::EarningRules::POLICY_NAMESPACE, "report_problem_effective_at", Time.current.iso8601)
          main = report(created_at: 2.days.ago)
          duplicate = report(created_at: 1.day.ago)
          earn_report(main)
          earn_report(duplicate)
          corrected = decide(duplicate, status: "odbijeno", action: "duplicate", duplicate_of: main)
          assert_equal 5, corrected.target_amount
          assert_nil G::CorroborateReport.call(report: main, user: @user).transaction
          assert_equal 25, @account.reload.contribution_score
        end

        test "proposal admission uses first source publication and Sarajevo month not job arrival" do
          component = FactoryBot.create(:proposal_component, organization: @organization)
          first = FactoryBot.create(:proposal, component:, users: [@user], published_at: Time.iso8601("2026-09-30T23:59:00+02:00"))
          second = FactoryBot.create(:proposal, component:, users: [@user], published_at: Time.iso8601("2026-09-30T23:59:30+02:00"))
          following = FactoryBot.create(:proposal, component:, users: [@user], published_at: Time.iso8601("2026-10-01T00:00:00+02:00"))
          assert_nil @rules.award(@user, :proposal, idempotency_key: G::IdempotencyKey.proposal(second.id, @user.id))
          assert_equal 25, @rules.award(@user, :proposal, idempotency_key: G::IdempotencyKey.proposal(first.id, @user.id)).credited_amount
          assert_equal 25, @rules.award(@user, :proposal, idempotency_key: G::IdempotencyKey.proposal(following.id, @user.id)).credited_amount
          assert_nil @rules.award(@user, :proposal, idempotency_key: G::IdempotencyKey.proposal(second.id, @user.id))
          assert_equal 50, @account.reload.contribution_score
          assert_equal Date.new(2026, 9, 1), G::AwardAdmission.find_by!(source_key: G::IdempotencyKey.proposal(first.id, @user.id)).period_start
        end

        test "transfer UUID replay binds recipient amount and payload before the balance guard" do
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(@user, 20, reason: "manual")
          args = { from_owner: @user, to_owner: other, amount: 20, kind: "gift", reason: "gift", idempotency_key: "uuid", metadata: { category: "gift" } }
          original = @ledger.transfer(**args)
          assert_equal original.id, @ledger.transfer(**args).id
          assert_raises(ArgumentError) { @ledger.transfer(**args.merge(amount: 10)) }
          assert_raises(ArgumentError) { @ledger.transfer(**args.merge(metadata: { category: "different" })) }
          assert_equal [0, 20], [@account.reload.balance, @account.contribution_score]
        end

        test "manual report revocation can settle pending and can be repeated after a later reinstatement" do
          source = report
          original = earn_report(source)
          @ledger.spend(owner: @user, amount: 20, kind: "redeem")
          first = G::SourceCreditCorrection.revoke(original, actor: @admin)
          assert_equal "admin_pending", first.settlement.status
          @ledger.award(@user, 30, reason: "other")
          G::SourceCreditCorrection.settle!(first, actor: @admin)
          assert_equal 10, @account.reload.balance
          source.record_event!("case_decision_applied", actor: @admin, metadata: { action: "reopen" })
          G::SourceCreditCorrection.call(report: source)
          second = G::SourceCreditCorrection.revoke(original, actor: @admin)
          refute_equal first.id, second.id
          assert_equal(-20, second.recognition_delta)
          assert_equal 10, @account.reload.balance
        end

        test "a private correction receipt is created exactly once and contains no public report author activity" do
          source = report(anonymous: true)
          earn_report(source)
          correction = decide(source, status: "odbijeno", action: "reject")
          notifications = -> { Decidim::Notification.where(user: @user, event_class: G::CreditCorrectedEvent.name).count }
          assert_difference notifications, 1 do
            2.times { G::SourceCreditCorrectionNoticeJob.perform_now(correction.id) }
          end
          notification = Decidim::Notification.where(user: @user, event_class: G::CreditCorrectedEvent.name).last
          assert_equal @user, notification.resource
          assert_equal source.reference, notification.extra["report_reference"]
          assert correction.settlement.reload.notified_at
        end

        test "active organization operators and opt-outs are excluded before deterministic ranking" do
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(@user, 50, reason: "manual")
          @ledger.award(other, 50, reason: "manual")
          other_account = @ledger.account_for(other)
          assert_equal 1, G::Account.rank_for(@account.reload)
          assert_equal 2, G::Account.rank_for(other_account.reload)
          role = OperatorRole.create!(organization: @organization, user: @user, role: "analytics_viewer", expires_at: 1.day.from_now, created_by: @admin)
          assert_nil G::Account.rank_for(@account)
          assert_equal [other_account.id], G::Account.contribution_leaderboard(@organization).pluck(:id)
          role.update!(revoked_at: Time.current)
          assert_equal 1, G::Account.rank_for(@account)
          @user.update!(extended_data: @user.extended_data.merge("bih_public_recognition" => false))
          assert_nil G::Account.rank_for(@account)
          assert_equal 50, @account.reload.balance
        end

        test "new intake events durably recover a failed immediate award once at original source time" do
          source = report(created_at: 2.days.ago)
          source.record_event!("report_created", actor: @user, source: "public", actor_role: "citizen")
          intent = G::CorrectionIntent.where(report: source).last
          assert intent.persisted?
          assert_equal "report_created", intent.report_event.event_type
          assert_difference -> { G::Transaction.where(organization: @organization, reason: "report").count }, 1 do
            2.times { G::SourceCreditCorrectionJob.perform_now(intent.id) }
          end
          admission = G::AwardAdmission.find_by!(source_key: G::IdempotencyKey.report(source.id))
          assert_equal source.created_at.to_i, admission.occurred_at.to_i
          assert_equal 20, @account.reload.contribution_score
        end

        test "rolling back an intake event leaves neither intent nor a queued award" do
          source = report
          before = G::CorrectionIntent.count
          G::CorrectionIntent.transaction(requires_new: true) do
            source.record_event!("report_created", actor: @user, source: "public", actor_role: "citizen")
            raise ActiveRecord::Rollback
          end
          assert_equal before, G::CorrectionIntent.count
          refute G::Transaction.exists?(organization: @organization, idempotency_key: G::IdempotencyKey.report(source.id))
        end

        test "rollback cancels ledger journal and all after-commit effects" do
          source = report
          earn_report(source)
          before = G::Transaction.count
          G::Transaction.transaction(requires_new: true) do
            decide(source, status: "odbijeno", action: "reject")
            raise ActiveRecord::Rollback
          end
          assert_equal before, G::Transaction.count
          assert_equal [20, 20], [@account.reload.balance, @account.contribution_score]
          assert_empty G::CreditCorrection.where(account: @account)
        end
      end
    end
  end
end

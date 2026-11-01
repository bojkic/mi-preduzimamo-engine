# frozen_string_literal: true
require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class GoodwillReferralSettlementTest < ActiveSupport::TestCase
        G = Decidim::Bih::Goodwill
        setup do
          @organization = create_organization
          @referrer = FactoryBot.create(:user, :confirmed, organization: @organization)
          @area = build_komsiluk!(@organization)
          @now = Time.iso8601("2026-09-27T12:00:00+02:00")
        end
        def referral(at:, eligible: true)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          if eligible
            Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(12), granted_at: at)
            CitizenProfile.create!(organization: @organization, user:, komsiluk: @area, source: "dropdown", assigned_at: at)
          end
          G::Referral.create!(organization: @organization, referrer: @referrer, invitee: user, status: "pending", created_at: at)
        end

        test "oldest eligible queue pays ten and carries the eleventh into actual next-month slots" do
          rows = 11.times.map { |i| referral(at: @now - (15 - i).days) }
          paid = G::Referrals.settle_queue(@referrer, now: @now)
          assert_equal rows.first(10).map(&:id), paid.map(&:id)
          last = rows.last.reload
          assert_equal ["pending", "carryover"], [last.status, last.pending_reason]
          assert_equal Time.iso8601("2026-10-01T00:00:00+02:00"), last.next_attempt_at
          assert_empty G::Referrals.settle_queue(@referrer, now: @now)
          assert_equal [last.id], G::Referrals.settle_queue(@referrer, now: Time.iso8601("2026-10-01T00:01:00+02:00")).map(&:id)
          assert_equal 275, G::Ledger.new.account_for(@referrer).reload.balance
          assert_equal 11, G::Transaction.where(organization: @organization, reason: "referral").count
        end

        test "phone plus neighborhood suffices without waiting for asynchronous welcome earns" do
          row = referral(at: @now - 2.days)
          assert_empty G::Transaction.where(organization: @organization)
          Setting.put(@organization, G::EarningRules::SCHEDULE_NAMESPACE, "referral", 30)
          G::Referrals.settle_queue(@referrer, now: @now)
          assert_equal "rewarded", row.reload.status
          assert_equal 30, row.ledger_transaction.credited_amount
        end

        test "current verification neighborhood and delay are rechecked with explicit pending reasons" do
          recent = referral(at: @now - 1.hour)
          unverified = referral(at: @now - 2.days, eligible: false)
          revoked = referral(at: @now - 3.days)
          Decidim::Authorization.where(user: revoked.invitee, name: "sms").update_all(granted_at: nil)
          G::Referrals.settle_queue(@referrer, now: @now)
          assert_equal "waiting_delay", recent.reload.pending_reason
          assert_equal "waiting_eligibility", unverified.reload.pending_reason
          assert_equal "waiting_eligibility", revoked.reload.pending_reason
          assert_equal 0, G::Ledger.new.account_for(@referrer).reload.balance
        end

        test "bounded recovery is tenant scoped and cannot pay blocked actors" do
          row = referral(at: @now - 2.days)
          row.invitee.update!(blocked: true, blocked_at: @now)
          G::Referrals.retry_pending(organization: @organization, now: @now)
          assert_equal "waiting_eligibility", row.reload.pending_reason
          assert_equal "pending", row.status
          assert_equal 0, G::Referrals.retry_pending(organization: create_organization, now: @now)
        end
      end
    end
  end
end

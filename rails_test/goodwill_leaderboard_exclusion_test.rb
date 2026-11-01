# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # DB-backed proof that the PUBLIC recognition leaderboard
      # (Account.contribution_leaderboard[_since]) excludes organization staff —
      # admins, role holders, and managed accounts — while ordinary citizens
      # still rank. The exclusion RULE is also unit-covered host-free in
      # test/models/decidim/bih/goodwill/account_leaderboard_test.rb; this
      # exercises the live public_leaderboard_accounts SQL scope against Postgres.
      class GoodwillLeaderboardExclusionTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @ledger = Decidim::Bih::Goodwill::Ledger.new

          @citizen_top = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Citizen Top")
          @citizen_low = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Citizen Low")
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization, name: "Administrator")
          @managed = FactoryBot.create(:user, :managed, organization: @organization, name: "Managed")
          @staff = FactoryBot.create(
            :user, :confirmed, organization: @organization, name: "Process Admin", roles: ["admin"]
          )

          # Give every account a contribution score; the staff accounts even
          # out-earn the citizens, so a missing filter would surface them at the
          # very top of the board.
          @ledger.award(@admin, 1_000, reason: "leaderboard_test_seed")
          @ledger.award(@staff, 900, reason: "leaderboard_test_seed")
          @ledger.award(@managed, 800, reason: "leaderboard_test_seed")
          @ledger.award(@citizen_top, 300, reason: "leaderboard_test_seed")
          @ledger.award(@citizen_low, 100, reason: "leaderboard_test_seed")
        end

        test "all-time public leaderboard excludes admins, role holders and managed accounts" do
          rows = Decidim::Bih::Goodwill::Account.contribution_leaderboard(@organization, limit: 25)
          owner_ids = rows.map(&:owner_id)

          assert_equal [@citizen_top.id, @citizen_low.id], owner_ids,
                       "only ordinary citizens rank, highest-earning first"

          refute_includes owner_ids, @admin.id, "an organization admin must not appear on the public board"
          refute_includes owner_ids, @staff.id, "a staff/role holder must not appear on the public board"
          refute_includes owner_ids, @managed.id, "a managed account must not appear on the public board"
        end

        test "windowed public leaderboard applies the same staff exclusion" do
          rows = Decidim::Bih::Goodwill::Account.contribution_leaderboard_since(
            @organization, since: 1.day.ago, limit: 25
          )
          owner_ids = rows.map(&:owner_id)

          assert_equal [@citizen_top.id, @citizen_low.id], owner_ids
          refute_includes owner_ids, @admin.id
          refute_includes owner_ids, @staff.id
          refute_includes owner_ids, @managed.id
        end

        test "legacy blank role values stay eligible in Ruby SQL and private rank" do
          account = @ledger.account_for(@citizen_low)
          [nil, [nil], [""], [" \t"], [nil, ""]].each do |roles|
            # Legacy role arrays may predate the current user validations.
            @citizen_low.update_columns(roles: roles)
            refute Decidim::Bih::Goodwill::Account.excluded_from_public_leaderboard?(@citizen_low.reload),
                   "blank roles #{roles.inspect} are not a staff grant"
            assert_equal [@citizen_top.id, @citizen_low.id],
                         Decidim::Bih::Goodwill::Account.contribution_leaderboard(@organization).map(&:owner_id)
            assert_equal [@citizen_top.id, @citizen_low.id],
                         Decidim::Bih::Goodwill::Account.contribution_leaderboard_since(@organization, since: 1.day.ago).map(&:owner_id)
            assert_equal 2, Decidim::Bih::Goodwill::Account.rank_for(account)
          end
        end

        test "the authoritative blocked flag is consistent across Ruby and SQL eligibility" do
          account = @ledger.account_for(@citizen_low)
          @citizen_low.update_columns(blocked: true, blocked_at: nil)
          assert Decidim::Bih::Goodwill::Account.excluded_from_public_leaderboard?(@citizen_low.reload)
          assert_equal [@citizen_top.id], Decidim::Bih::Goodwill::Account.contribution_leaderboard(@organization).map(&:owner_id)
          assert_nil Decidim::Bih::Goodwill::Account.rank_for(account)

          @citizen_low.update_columns(blocked: false, blocked_at: 1.day.ago)
          refute Decidim::Bih::Goodwill::Account.excluded_from_public_leaderboard?(@citizen_low.reload)
          assert_equal [@citizen_top.id, @citizen_low.id],
                       Decidim::Bih::Goodwill::Account.contribution_leaderboard(@organization).map(&:owner_id)
          assert_equal 2, Decidim::Bih::Goodwill::Account.rank_for(account)
        end

        test "excluded staff keep their wallet but have no public recognition rank" do
          admin_account = @ledger.account_for(@admin)

          assert_equal 1_000, admin_account.balance
          assert_equal 1_000, admin_account.contribution_score
          assert_nil Decidim::Bih::Goodwill::Account.rank_for(admin_account)
        end
      end
    end
  end
end

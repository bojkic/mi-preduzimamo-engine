# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class LaunchInvitationIssueTest < ActiveSupport::TestCase
        Service = Decidim::Bih::Goodwill::LaunchInvitation

        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
          @reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20,
            stock: 2,
            deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
        end

        test "issues at the threshold without deducting points" do
          @ledger.award(@citizen, 20, reason: "test_seed")
          balance_before = @ledger.account_for(@citizen).reload.balance

          invitation = Service.issue_for(@citizen)

          assert invitation, "pozivnica se izdaje na 20 bodova"
          assert_equal balance_before, @ledger.account_for(@citizen).reload.balance,
                       "bodovi se NE oduzimaju"
          assert_nil invitation.ledger_transaction
          assert_predicate invitation, :auto_issued?
          assert_equal "reserved", invitation.status
          assert invitation.entry_code.present?
          assert invitation.confirmation_deadline_at.present?
        end

        test "does not issue below the threshold" do
          @ledger.award(@citizen, 19, reason: "test_seed")

          assert_nil Service.issue_for(@citizen)
        end

        test "issues at most one invitation per citizen even under repeated calls" do
          @ledger.award(@citizen, 100, reason: "test_seed")

          first = Service.issue_for(@citizen)
          second = Service.issue_for(@citizen)
          third = Service.issue_for(@citizen)

          assert first
          assert_equal first.id, second.id, "ponovljeni poziv vraća istu pozivnicu"
          assert_equal first.id, third.id
          assert_equal 1, Decidim::Bih::Goodwill::RewardFulfillment
            .where(organization: @organization, reward_key: Service::REWARD_KEY).count
        end

        test "stops issuing when the current wave stock is exhausted" do
          2.times do |i|
            other = FactoryBot.create(:user, :confirmed, organization: @organization)
            @ledger.award(other, 50, reason: "test_seed_#{i}")
            assert Service.issue_for(other)
          end

          assert_equal 0, Service.remaining(@organization)

          @ledger.award(@citizen, 50, reason: "test_seed_last")
          assert_nil Service.issue_for(@citizen), "iscrpljena zaliha ne izdaje"
        end

        test "does not issue after the deadline" do
          @ledger.award(@citizen, 50, reason: "test_seed")

          travel_to Time.zone.parse("2026-09-17 00:01") do
            assert_nil Service.issue_for(@citizen)
          end
        end

        test "enabled? turns false once the reward has expired" do
          assert Service.enabled?(@organization), "aktivna, neistekla nagrada mora ostati uključena"

          travel_to Time.zone.parse("2026-09-17 00:01") do
            Rails.cache.clear
            refute Service.enabled?(@organization),
                   "istekla nagrada mora ugasiti okidač — inače bi Ledger zauvijek zakazivao job na svakom earn-u"
          end
        end

        test "returns an already issued invitation even after the deadline has passed" do
          @ledger.award(@citizen, 50, reason: "test_seed")
          issued = Service.issue_for(@citizen)
          assert issued, "pozivnica se izdaje prije roka"

          travel_to Time.zone.parse("2026-09-17 00:01") do
            again = Service.issue_for(@citizen)

            refute_nil again, "već izdata pozivnica važi bez obzira na rok"
            assert_equal issued.id, again.id
          end
        end

        test "entry codes are unpredictable, not sequential" do
          codes = 200.times.map { Service.generate_entry_code }

          assert_equal codes.uniq.length, codes.length, "kodovi se ne smiju ponavljati"
          codes.each { |code| assert_match(/\AMI-[A-Z2-9]{5}-[A-Z2-9]{5}\z/, code) }
          refute_equal codes.sort, codes, "kodovi ne smiju biti redni brojevi"
        end

        test "staff and managed accounts are not auto issued invitations" do
          admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @ledger.award(admin, 100, reason: "test_seed")

          assert_nil Service.issue_for(admin)
        end

        test "a managed account is not auto issued an invitation" do
          managed = FactoryBot.create(:user, :managed, organization: @organization)
          @ledger.award(managed, 100, reason: "test_seed")

          assert_nil Service.issue_for(managed)
        end

        test "a staff role holder is not auto issued an invitation" do
          staff = FactoryBot.create(
            :user, :confirmed, organization: @organization, roles: ["admin"]
          )
          @ledger.award(staff, 100, reason: "test_seed")

          assert_nil Service.issue_for(staff)
        end

        test "a citizen who opted out of the public leaderboard still gets the invitation" do
          citizen = FactoryBot.create(
            :user, :confirmed, organization: @organization,
                               extended_data: { "bih_public_recognition" => false }
          )
          @ledger.award(citizen, 40, reason: "test_seed")

          invitation = Service.issue_for(citizen)

          assert invitation, "odustanak od javnog priznanja ne oduzima pravo na pozivnicu"
        end
      end
    end
  end
end

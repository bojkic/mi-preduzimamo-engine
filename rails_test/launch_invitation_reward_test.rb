# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class LaunchInvitationRewardTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
        end

        test "config-backed rewards always deduct points" do
          # Ovaj harness generiše host bez ijedne konfigurisane nagrade, pa
          # config_rewards inače vraća prazan niz — zasadimo jednu da bismo
          # provjerili da RewardsCatalog::Reward#deducts_points ostaje true.
          original_catalog = Decidim::Bih.goodwill_rewards_catalog
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "community_thanks", cost: 50 }]

          reward = Decidim::Bih::Goodwill::RewardsCatalog.config_rewards.first

          assert_predicate reward, :deducts_points
        ensure
          Decidim::Bih.goodwill_rewards_catalog = original_catalog
        end

        test "a table-backed reward can be marked as a threshold, not a purchase" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key: "pozivnica_lansiranje",
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20,
            stock: 150,
            deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )

          refute_predicate reward, :deducts_points?
          assert_predicate reward, :auto_issue_at_threshold?
        end

        test "the existing 400-point invitation still deducts points" do
          existing = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key: "pozivnica",
            title: { "sr" => "Pozivnica za događaj zajednice" },
            cost: 400
          )

          assert_predicate existing, :deducts_points?
          refute_predicate existing, :auto_issue_at_threshold?
        end

        test "a fulfillment without a ledger transaction is valid only when auto issued" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)

          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.new(
            organization: @organization,
            user: citizen,
            reward_key: "pozivnica_lansiranje",
            cost: 40,
            status: "reserved",
            auto_issued: true,
            ledger_transaction: nil
          )

          assert_predicate fulfillment, :valid?

          manual = fulfillment.dup
          manual.auto_issued = false

          refute_predicate manual, :valid?,
                           "ručno preuzimanje mora imati ledger transakciju"
        end

        test "an auto issued fulfillment must NOT carry a ledger transaction" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          transaction = Decidim::Bih::Goodwill::Ledger.new.award(citizen, 40, reason: "test_seed")

          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.new(
            organization: @organization,
            user: citizen,
            reward_key: "pozivnica_lansiranje",
            cost: 40,
            status: "reserved",
            auto_issued: true,
            ledger_transaction: transaction
          )

          refute_predicate fulfillment, :valid?,
                           "automatski izdata pozivnica ne smije nositi transakciju skidanja bodova"
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class GoodwillRedemptionFlowTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @ledger = Decidim::Bih::Goodwill::Ledger.new
        end

        test "redeems and cancels a table-backed reward through public and admin routes" do
          reward = create_table_reward!(
            organization: @organization,
            key: "rails_majica",
            cost: 500,
            stock: 1,
            title: "Rails majica"
          )

          @ledger.award(@citizen, 600, reason: "rails_harness_seed")

          sign_in @citizen
          assert_difference "Decidim::Bih::Goodwill::RewardFulfillment.count", 1 do
            assert_difference "Decidim::Bih::Goodwill::RewardFulfillmentEvent.count", 1 do
              post redeem_path(reward.key), params: redemption_params
            end
          end

          assert_response :redirect
          assert_equal 100, @ledger.account_for(@citizen).reload.balance

          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.order(:id).last
          assert_equal @organization, fulfillment.organization
          assert_equal @citizen, fulfillment.user
          assert_equal reward.key, fulfillment.reward_key
          assert_equal 500, fulfillment.cost
          assert_equal "requested", fulfillment.status
          assert_equal "redeem", fulfillment.ledger_transaction.kind

          requested_event = fulfillment.events.where(event_type: "requested").last
          assert_equal @citizen, requested_event.actor
          assert_equal "public", requested_event.source
          assert_equal "citizen", requested_event.actor_role
          assert_equal "redemption", requested_event.metadata["action"]
          assert_equal reward.key, requested_event.metadata["reward_key"]
          assert_equal 500, requested_event.metadata["cost"]

          sign_out @citizen
          sign_in @admin
          assert_no_difference -> { fulfillment.events.where(event_type: "canceled").count } do
            assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.where(organization: @organization).count } do
              post admin_reward_fulfillment_path(fulfillment, "canceled")
            end
          end
          assert_response :redirect
          assert_equal "requested", fulfillment.reload.status

          assert_difference -> { fulfillment.events.where(event_type: "canceled").count }, 1 do
            assert_difference -> { Decidim::Bih::Goodwill::Transaction.where(organization: @organization).count }, 1 do
              post admin_reward_fulfillment_path(fulfillment, "canceled"),
                   params: { private_reason: "Duplicate pickup request confirmed" }
            end
          end

          assert_response :redirect
          assert_equal "canceled", fulfillment.reload.status
          assert_equal @admin.id, fulfillment.handled_by_id
          assert_equal 600, @ledger.account_for(@citizen).reload.balance

          reversal = Decidim::Bih::Goodwill::Transaction.find_by!(
            organization: @organization,
            idempotency_key: "reversal_of:#{fulfillment.ledger_transaction.id}"
          )
          assert_equal "adjustment", reversal.kind

          canceled_event = fulfillment.events.where(event_type: "canceled").last
          assert_equal @admin, canceled_event.actor
          assert_equal "single", canceled_event.metadata["action"]
          assert_equal reversal.id, canceled_event.metadata["reversal_transaction_id"]
          assert_equal "Duplicate pickup request confirmed", canceled_event.metadata["private_reason"]

          audit_event = Decidim::Bih::OperatorAuditEvent.where(
            event_type: "reward_fulfillment_updated",
            resource_id: fulfillment.id
          ).last
          assert_equal "Duplicate pickup request confirmed", audit_event.metadata["private_reason"]

          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          @ledger.award(other, 600, reason: "rails_harness_seed")
          sign_out @admin
          sign_in other

          assert_difference -> { Decidim::Bih::Goodwill::RewardFulfillment.where(reward_key: reward.key).count }, 1 do
            post redeem_path(reward.key), params: redemption_params
          end
          assert_response :redirect
          assert_equal 100, @ledger.account_for(other).reload.balance
        end

        test "admin cancellation is organization scoped" do
          other_organization = create_organization
          outsider = FactoryBot.create(:user, :confirmed, organization: other_organization)
          other_ledger = Decidim::Bih::Goodwill::Ledger.new
          reward = create_table_reward!(
            organization: other_organization,
            key: "other_majica",
            cost: 200,
            stock: 1,
            title: "Other majica"
          )
          other_ledger.award(outsider, 300, reason: "rails_harness_seed")
          Decidim::Bih::Goodwill::RedeemReward.call(outsider, reward.key)
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.where(organization: other_organization).last

          sign_in @admin
          assert_no_difference "Decidim::Bih::Goodwill::RewardFulfillmentEvent.count" do
            assert_no_difference "Decidim::Bih::Goodwill::Transaction.count" do
              post admin_reward_fulfillment_path(fulfillment, "canceled"),
                   params: { private_reason: "Wrong tenant must remain untouched" }
            end
          end

          assert_response :redirect
          assert_equal "requested", fulfillment.reload.status
          assert_nil fulfillment.handled_by_id
          assert_equal 100, other_ledger.account_for(outsider).reload.balance
        end

        test "batch cancellation records bounded reason and aggregate effect counts" do
          reward = create_table_reward!(
            organization: @organization,
            key: "batch_majica",
            cost: 200,
            stock: 3,
            title: "Batch majica"
          )
          second_citizen = FactoryBot.create(:user, :confirmed, organization: @organization)

          [@citizen, second_citizen].each do |citizen|
            @ledger.award(citizen, 300, reason: "rails_harness_seed")
            Decidim::Bih::Goodwill::RedeemReward.call(citizen, reward.key)
          end
          selected, terminal = Decidim::Bih::Goodwill::RewardFulfillment
                               .where(organization: @organization, reward_key: reward.key)
                               .order(:id)
                               .to_a
          terminal.mark!("fulfilled", by: @admin)

          sign_in @admin
          post "/admin/bih/goodwill/reward-fulfillments/batch",
               params: {
                 fulfillment_ids: [selected.id, terminal.id],
                 batch_status: "canceled",
                 private_reason: "Event duplicate; refund requested"
               }

          assert_response :redirect
          assert_equal "canceled", selected.reload.status
          assert_equal "fulfilled", terminal.reload.status
          event = selected.events.where(event_type: "canceled").last
          assert_equal "batch", event.metadata["action"]
          assert_equal 2, event.metadata["selected_count"]
          assert_equal 1, event.metadata["eligible_count"]
          assert_equal "Event duplicate; refund requested", event.metadata["private_reason"]
        end

        test "ledger reversal requires and privately audits a bounded reason" do
          transaction = @ledger.award(@citizen, 30, reason: "rails_harness_seed")
          sign_in @admin

          assert_no_difference "Decidim::Bih::Goodwill::Transaction.count" do
            post "/admin/bih/goodwill/transaction/#{transaction.id}/reverse"
          end
          assert_equal 30, @ledger.account_for(@citizen).reload.balance

          assert_difference "Decidim::Bih::Goodwill::Transaction.count", 1 do
            post "/admin/bih/goodwill/transaction/#{transaction.id}/reverse",
                 params: { private_reason: "Duplicate manual award" }
          end
          assert_response :redirect
          assert_equal 0, @ledger.account_for(@citizen).reload.balance

          audit_event = Decidim::Bih::OperatorAuditEvent.where(
            event_type: "goodwill_transaction_reversed",
            resource_id: transaction.id
          ).last
          assert_equal "Duplicate manual award", audit_event.metadata["private_reason"]
        end
      end
    end
  end
end

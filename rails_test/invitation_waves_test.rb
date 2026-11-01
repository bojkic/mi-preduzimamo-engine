# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Integration coverage for Decidim::Bih::Launch::InvitationWaves#count_issued
      # and #degraded? against real Postgres. The fast suite only ever injects
      # issued_count: and organization: nil, so the hand-written SQL against
      # decidim_bih_goodwill_reward_fulfillments has never actually executed
      # before this file.
      #
      # The fulfillments/transactions rows below are inserted with raw SQL
      # against the tables directly — never through
      # Decidim::Bih::Goodwill::RewardFulfillment, ::Transaction, ::Reward, or
      # any other class under goodwill/. Those belong to the parallel
      # recalibration branch and are off-limits here; only the FK-mandated
      # organization/user rows come from ordinary (non-goodwill) factories.
      class InvitationWavesTest < ActiveSupport::TestCase
        REWARD_KEY = "pozivnica_lansiranje"
        SINGLE_WAVE = [{ "starts_on" => "2026-09-06", "quantity" => 310 }].freeze

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @original_waves = Decidim::Bih.launch_invitation_waves
          @original_reward_key = Decidim::Bih.launch_invitation_reward_key
          Decidim::Bih.launch_invitation_waves = SINGLE_WAVE
          Decidim::Bih.launch_invitation_reward_key = REWARD_KEY
          @now = Time.zone.parse("2026-09-10 12:00:00")
        end

        teardown do
          Decidim::Bih.launch_invitation_waves = @original_waves
          Decidim::Bih.launch_invitation_reward_key = @original_reward_key
        end

        # Inserted with raw SQL against the table, never through a goodwill/
        # model class — see the class comment above.
        def insert_transaction!(organization: @organization)
          result = ActiveRecord::Base.connection.execute(
            ActiveRecord::Base.sanitize_sql_array(
              [
                "INSERT INTO decidim_bih_goodwill_transactions " \
                "(decidim_organization_id, kind, created_at, updated_at) " \
                "VALUES (:org, 'redeem', now(), now()) RETURNING id",
                { org: organization.id }
              ]
            )
          )
          result.first["id"].to_i
        end

        def insert_fulfillment!(status:, organization: @organization, user: @user, reward_key: REWARD_KEY)
          transaction_id = insert_transaction!(organization:)
          ActiveRecord::Base.connection.execute(
            ActiveRecord::Base.sanitize_sql_array(
              [
                "INSERT INTO decidim_bih_goodwill_reward_fulfillments " \
                "(decidim_organization_id, decidim_bih_goodwill_transaction_id, decidim_user_id, " \
                "reward_key, cost, status, created_at, updated_at) " \
                "VALUES (:org, :txn, :user, :key, :cost, :status, now(), now())",
                {
                  org: organization.id,
                  txn: transaction_id,
                  user: user.id,
                  key: reward_key,
                  cost: 1,
                  status: status
                }
              ]
            )
          )
        end

        def subject(now: @now)
          Decidim::Bih::Launch::InvitationWaves.new(organization: @organization, now:)
        end

        test "with no fulfillment rows, issued is 0 and remaining is 310" do
          instance = subject

          assert_equal 0, instance.issued
          assert_equal 310, instance.remaining
          refute instance.degraded?
        end

        test "requested, reserved and fulfilled rows each count as issued" do
          insert_fulfillment!(status: "requested")
          insert_fulfillment!(status: "reserved")
          insert_fulfillment!(status: "fulfilled")

          instance = subject

          assert_equal 3, instance.issued
          assert_equal 307, instance.remaining
        end

        test "canceled and reversed rows do not count as issued" do
          insert_fulfillment!(status: "canceled")
          insert_fulfillment!(status: "reversed")

          instance = subject

          assert_equal 0, instance.issued
          assert_equal 310, instance.remaining
        end

        test "a row for a different reward_key does not count" do
          insert_fulfillment!(status: "requested", reward_key: "some_other_reward")

          instance = subject

          assert_equal 0, instance.issued
          assert_equal 310, instance.remaining
        end

        test "a row for a different organization does not count" do
          other_organization = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other_organization)
          insert_fulfillment!(status: "requested", organization: other_organization, user: other_user)

          instance = subject

          assert_equal 0, instance.issued
          assert_equal 310, instance.remaining
        end

        test "a mix of counted, excluded-status, wrong-key and wrong-org rows only counts the eligible ones" do
          insert_fulfillment!(status: "requested")
          insert_fulfillment!(status: "reserved")
          insert_fulfillment!(status: "fulfilled")
          insert_fulfillment!(status: "canceled")
          insert_fulfillment!(status: "reversed")
          insert_fulfillment!(status: "requested", reward_key: "some_other_reward")

          other_organization = create_organization
          other_user = FactoryBot.create(:user, :confirmed, organization: other_organization)
          insert_fulfillment!(status: "requested", organization: other_organization, user: other_user)

          instance = subject

          assert_equal 3, instance.issued
          assert_equal 307, instance.remaining
        end

        test "degraded? is true when the issued count query fails, and the counter still fails to 0" do
          instance = subject

          ActiveRecord::Base.connection.stub(:select_value, ->(*) { raise "simulated query failure" }) do
            assert_equal 0, instance.issued
            assert instance.degraded?
          end
        end

        test "degraded? is false on the normal path, including the legitimate zero-issued case" do
          instance = subject

          assert_equal 0, instance.issued
          refute instance.degraded?
        end
      end
    end
  end
end

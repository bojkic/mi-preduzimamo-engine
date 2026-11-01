# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Redeems a catalog reward for a citizen, debiting their wallet. Broadcasts:
      #   :ok              -> reward redeemed (yields the reward)
      #   :invalid         -> no such reward / no user
      #   :insufficient    -> wallet can't cover the cost
      #   :auto_issue_only -> reward is a threshold prag (auto_issue_at_threshold);
      #                       the system issues it alone, never a manual redeem
      class RedeemReward < Decidim::Command
        def initialize(user, reward_key, request_key = nil)
          @user = user
          @reward_key = reward_key
          @request_key = request_key.to_s.presence || SecureRandom.uuid
        end

        def call
          organization = @user&.organization
          # Resolve against THIS organization's catalog so a table-backed reward
          # (admin-managed) takes precedence over the legacy config list.
          reward = RewardsCatalog.find(@reward_key, organization)
          # Guard a misconfigured catalog (cost <= 0/non-numeric) so a host typo
          # degrades to :invalid instead of a 500 from Ledger#spend.
          return broadcast(:invalid) unless valid_request?(reward)

          # Prag-nagrade (auto_issue_at_threshold) izdaje SAMO sistem, na
          # prelasku praga — nikad ručni klik. Bez ove provjere bi #redeem!
          # ispod bezuslovno skinuo bodove za nagradu koja NIKAD ne smije
          # oduzeti bodove, i to ponovljeno na svaki klik, jer ovaj put ne
          # prolazi kroz jedinstveni indeks koji čuva samo automatsko izdavanje.
          return broadcast(:auto_issue_only) if reward.auto_issue_at_threshold?

          existing = RewardFulfillment.find_by(organization:, user: @user, request_key: @request_key)
          return broadcast(:already, reward) if existing

          # Expired rewards cannot be redeemed.
          return broadcast(:expired) if reward.expired?

          redeem!(organization, reward)
          broadcast(:ok, reward)
        rescue StockExhaustedError
          broadcast(:out_of_stock)
        rescue Decidim::Bih::Goodwill::InsufficientBalanceError
          broadcast(:insufficient)
        rescue ArgumentError
          broadcast(:invalid)
        rescue ActiveRecord::RecordNotUnique
          broadcast(:already, reward)
        end

        private

        def valid_request?(reward)
          @user.present? && reward.present? && reward.cost.positive? &&
            @request_key.match?(RewardFulfillment::REQUEST_KEY_PATTERN)
        end

        def redeem!(organization, reward)
          ActiveRecord::Base.transaction do
            AdvisoryLock.acquire!("goodwill-reward-stock:#{organization.id}:#{reward.key}")
            reward.lock! if reward.respond_to?(:lock!) && reward.persisted?
            raise StockExhaustedError if reward.stock.present? && reward.remaining_stock(organization) <= 0

            transaction = Ledger.new.spend(
              owner: @user,
              amount: reward.cost,
              kind: "redeem",
              reason: "reward:#{reward.key}",
              idempotency_key: "reward-redemption:#{@user.id}:#{@request_key}",
              metadata: { reward: reward.key }
            )
            fulfillment = RewardFulfillment.create!(
              organization:,
              ledger_transaction: transaction,
              user: @user,
              reward_key: reward.key,
              request_key: @request_key,
              cost: reward.cost,
              status: "requested",
              reward_expires_at: reward.expires_at
            )
            fulfillment.record_event!(
              "requested",
              actor: @user,
              source: "public",
              actor_role: "citizen",
              metadata: {
                from_status: nil,
                to_status: "requested",
                reward_key: reward.key,
                cost: reward.cost,
                ledger_transaction_id: transaction.id,
                action: "redemption"
              }
            )
          end
        end
      end
    end
  end
end

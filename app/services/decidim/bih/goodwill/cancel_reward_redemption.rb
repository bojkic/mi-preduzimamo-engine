# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Citizen cancellation before operator reservation; refunds through an
      # append-only reversal and records fulfillment history under one row lock.
      class CancelRewardRedemption
        def self.call(fulfillment:, user:)
          new(fulfillment:, user:).call
        end

        def initialize(fulfillment:, user:)
          @fulfillment = fulfillment
          @user = user
        end

        def call
          return :missing unless fulfillment
          return :forbidden unless user && fulfillment.user == user && fulfillment.organization == user.organization

          result = :invalid
          fulfillment.with_lock do
            if fulfillment.status.in?(%w(canceled reversed))
              result = :already
              next
            end
            next unless fulfillment.citizen_cancelable?

            if fulfillment.auto_issued?
              fulfillment.mark!("canceled", by: user, source: "public", actor_role: "citizen",
                                metadata: { action: "citizen_cancel", refunded: 0 })
            else
              Ledger.new.reverse(fulfillment.ledger_transaction, actor: user, fulfillment_status: "canceled",
                                 fulfillment_source: "public", fulfillment_metadata: { action: "citizen_cancel" })
            end
            result = :ok
          end
          result
        rescue ActiveRecord::RecordInvalid
          :invalid
        end

        private

        attr_reader :fulfillment, :user
      end
    end
  end
end

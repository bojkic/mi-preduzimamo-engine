# frozen_string_literal: true

module Decidim
  module Bih
    # Closes an obsolete approved need without erasing contribution history.
    # Offered and accepted proposals are declined to release reservations;
    # delivered help must first be confirmed or otherwise resolved.
    class CancelContributionNeed
      def self.call(need:, actor:)
        new(need:, actor:).call
      end

      def initialize(need:, actor:)
        @need = need
        @actor = actor
      end

      def call
        status = guard_status
        return status if status

        result = nil
        need.class.transaction do
          need.lock! if need.respond_to?(:lock!)
          need.partner_profile.lock! if need.partner_profile.respond_to?(:lock!)
          result = cancel_locked
        end
        result
      rescue ActiveRecord::RecordInvalid
        :invalid
      end

      private

      attr_reader :need, :actor

      def guard_status
        return :missing if need.blank?
        return :forbidden unless actor.present? && actor.organization == need.organization
        return :forbidden unless need.managed_by?(actor)
        return :already if need.cancelled?

        :invalid unless need.approved? && need.open?
      end

      def cancel_locked
        status = locked_guard_status
        return status if status

        offers = need.offers.lock.to_a
        return :delivered_pending_confirmation if offers.any?(&:delivered?)

        now = Time.current
        decline_open_offers!(offers, now:)
        need.update!(fulfillment_status: "cancelled", closed_at: now)
        :ok
      end

      def locked_guard_status
        return :already if need.cancelled?
        return :invalid unless need.approved? && need.open?

        :forbidden unless need.managed_by?(actor)
      end

      def decline_open_offers!(offers, now:)
        offers.select { |offer| offer.offered? || offer.accepted? }.each do |offer|
          offer.update!(
            status: "declined",
            declined_by: actor,
            declined_at: now,
            decline_reason: nil
          )
        end
      end
    end
  end
end

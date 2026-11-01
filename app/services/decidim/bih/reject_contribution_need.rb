# frozen_string_literal: true

module Decidim
  module Bih
    # Rejects a pending need; rejected content is never in the public scope.
    class RejectContributionNeed
      def self.call(need, reviewer:, reason:)
        new(need, reviewer:, reason:).call
      end

      def initialize(need, reviewer:, reason:)
        @need = need
        @reviewer = reviewer
        @reason = reason.to_s.strip
      end

      def call
        status = guard_status
        return status if status

        result = :ok
        need.class.transaction do
          need.lock! if need.respond_to?(:lock!)

          locked_status = guard_status
          if locked_status
            result = locked_status
            next
          end

          need.update!(
            review_status: "rejected",
            reviewer:,
            reviewed_at: Time.current,
            published_at: nil,
            rejection_reason: reason
          )
        end
        notify_author if result == :ok
        result
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError
        :invalid
      end

      private

      attr_reader :need, :reviewer, :reason

      def notify_author
        CommunityContributionNotifications.publish(
          transition: "need_rejected",
          item: need.title,
          affected_users: [need.author],
          path: CommunityContributionNotifications.public_path("volontiranje?tab=potrebe")
        )
      rescue StandardError => e
        Rails.logger&.error("[RejectContributionNeed] notification failed: #{e.class}") if Rails.respond_to?(:logger)
        nil
      end

      def guard_status
        return :missing if need.blank?
        return :already if need.rejected?
        return :invalid unless need.pending_review?
        return :invalid if reason.blank? || reason.length > need.class::MAX_REJECTION_REASON_LENGTH

        :invalid unless reviewer.present? && reviewer.organization == need.organization
      end
    end
  end
end

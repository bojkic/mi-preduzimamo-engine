# frozen_string_literal: true

module Decidim
  module Bih
    # Rejects a pending citizen-proposed volunteer opportunity with an operator
    # reason. No points are awarded on rejection.
    class RejectVolunteerOpportunity < ReviewDecision
      def self.call(opportunity, reviewer:, reason:)
        new(opportunity, reviewer:, reason:).call
      end

      def initialize(opportunity, reviewer:, reason:)
        super()
        @opportunity = opportunity
        @reviewer = reviewer
        @reason = reason.to_s.strip
      end

      private

      attr_reader :opportunity, :reviewer, :reason

      def guards
        [
          [:missing, -> { opportunity.blank? }],
          [:already, -> { opportunity.rejected? }],
          [:invalid, -> { !opportunity.pending_review? }],
          [:invalid, -> { reason.blank? }]
        ]
      end

      def transaction_model
        VolunteerOpportunity
      end

      def review_record
        opportunity
      end

      def perform
        opportunity.update!(
          active: false,
          review_status: "rejected",
          reviewer: reviewer,
          reviewed_at: Time.current,
          rejection_reason: reason
        )
      end

      def notify
        VolunteerNotifications.publish(
          user: opportunity.author,
          kind: :opportunity,
          status: :rejected,
          title: opportunity.title,
          reason: reason
        )
      end
    end
  end
end

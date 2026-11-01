# frozen_string_literal: true

module Decidim
  module Bih
    # Rejects a pending volunteer-hour log with an operator reason. Rejection does
    # not award points and does not mutate the Goodwill ledger.
    class RejectVolunteerLog < ReviewDecision
      def self.call(log, verifier:, reason:)
        new(log, verifier:, reason:).call
      end

      def initialize(log, verifier:, reason:)
        super()
        @log = log
        @verifier = verifier
        @reason = reason.to_s.strip
      end

      private

      attr_reader :log, :verifier, :reason

      def guards
        [
          [:missing, -> { log.blank? }],
          [:already, -> { !log.pending? }],
          [:invalid, -> { reason.blank? }]
        ]
      end

      def transaction_model
        Decidim::Bih::VolunteerLog
      end

      def review_record
        log
      end

      def perform
        log.update!(
          status: "rejected",
          verifier: verifier,
          verified_at: Time.current,
          rejection_reason: reason
        )
      end

      def notify
        VolunteerNotifications.publish(
          user: log.user,
          kind: :log,
          status: :rejected,
          title: log.opportunity.title,
          reason: reason
        )
      end
    end
  end
end

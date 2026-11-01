# frozen_string_literal: true

module Decidim
  module Bih
    # Rejects a submitted project without creating a public native resource.
    class RejectPartnerProjectSubmission
      def self.call(submission, reviewer:, reason:)
        new(submission, reviewer:, reason:).call
      end

      def initialize(submission, reviewer:, reason:)
        @submission = submission
        @reviewer = reviewer
        @reason = reason.to_s.strip
      end

      def call
        status = guard_status
        return status if status

        result = :ok
        submission.class.transaction do
          submission.lock! if submission.respond_to?(:lock!)

          locked_status = guard_status
          if locked_status
            result = locked_status
            next
          end

          submission.update!(
            review_status: "rejected",
            reviewer:,
            reviewed_at: Time.current,
            rejection_reason: reason
          )
        end
        notify_representative if result == :ok
        result
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError
        :invalid
      end

      private

      attr_reader :submission, :reviewer, :reason

      def notify_representative
        CommunityContributionNotifications.publish(
          transition: "project_rejected",
          item: submission.title,
          affected_users: [submission.representative],
          path: CommunityContributionNotifications.public_path("projekti/novi")
        )
      rescue StandardError => e
        Rails.logger&.error("[RejectPartnerProjectSubmission] notification failed: #{e.class}") if Rails.respond_to?(:logger)
        nil
      end

      def guard_status
        return :missing if submission.blank?
        return :already if submission.rejected?
        return :invalid unless submission.submitted?
        return :invalid if reason.blank? || reason.length > submission.class::MAX_REJECTION_REASON_LENGTH

        :invalid unless reviewer.present? && reviewer.organization == submission.organization
      end
    end
  end
end

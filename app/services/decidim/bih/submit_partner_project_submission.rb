# frozen_string_literal: true

module Decidim
  module Bih
    # Moves a partner's private draft into the LFBN review queue. Creation and
    # resubmission both require a current accepted content-manager membership.
    class SubmitPartnerProjectSubmission
      def self.call(submission, representative:)
        new(submission, representative:).call
      end

      def initialize(submission, representative:)
        @submission = submission
        @representative = representative
      end

      def call
        status = guard_status
        return status if status

        result = :ok
        submission.class.transaction do
          submission.lock! if submission.respond_to?(:lock!)
          submission.partner_profile.lock! if submission.partner_profile.respond_to?(:lock!)

          locked_status = guard_status
          if locked_status
            result = locked_status
            next
          end

          submission.update!(
            review_status: "submitted",
            representative:,
            submitted_at: Time.current,
            reviewer: nil,
            reviewed_at: nil,
            rejection_reason: nil
          )
        end
        result
      rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError
        :invalid
      end

      private

      attr_reader :submission, :representative

      def guard_status
        return :missing if submission.blank?
        return :already if submission.submitted? || submission.approved?
        return :invalid unless submission.draft? || submission.changes_requested?
        return :forbidden unless submission.partner_profile&.verified?

        :forbidden unless submission.represented_by_content_manager?(representative)
      end
    end
  end
end

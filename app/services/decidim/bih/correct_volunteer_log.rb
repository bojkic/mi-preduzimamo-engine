# frozen_string_literal: true

module Decidim
  module Bih
    # Corrects a previously approved claim without mutating ledger history.
    # A corrected claim can be resubmitted as a new dated interval; only the
    # final qualifying claim on a local date reverses that date's base award.
    class CorrectVolunteerLog
      def self.call(log, verifier:, reason:)
        new(log, verifier:, reason:).call
      end

      def initialize(log, verifier:, reason:)
        @log = log
        @verifier = verifier
        @reason = reason.to_s.strip
      end

      def call
        return :missing unless log
        return :invalid unless Decidim::Bih.volunteer_work_award_unit.to_sym == :day
        return :invalid if reason.blank? || reason.length > 1_000
        return :invalid unless authorized?

        result = :ok
        VolunteerLog.transaction do
          opportunity = VolunteerOpportunity.where(organization: log.organization).lock.find_by(id: log.opportunity.id)
          signup = opportunity&.signups&.lock&.find_by(user: log.user)
          if opportunity.nil? || signup.nil?
            result = :invalid
            raise ActiveRecord::Rollback
          end

          log.lock!
          log.user.lock!
          if !log.approved? || !authorized?
            result = :already
            raise ActiveRecord::Rollback
          end

          log.update!(status: "rejected", verifier:, verified_at: Time.current, rejection_reason: reason)
          reverse_bonus!(opportunity)
          Goodwill::VolunteerDailyAwards.reverse_if_unsupported(log) if log.work_date
          OperatorAuditEvent.record!(
            organization: log.organization, actor: verifier,
            event_type: "volunteer_work_corrected", permission: "volunteering_hours_review",
            resource: log, metadata: { previous_status: "approved", work_date: log.work_date&.iso8601,
                                      reason_present: true }
          )
        end
        result
      end

      private

      attr_reader :log, :verifier, :reason

      def authorized?
        verifier && verifier.organization == log.organization && verifier.id != log.user.id &&
          OperatorAuthorization.allowed?(
            verifier, :volunteering_hours_review, organization: log.organization, resource: log.opportunity
          )
      end

      def reverse_bonus!(_opportunity)
        Goodwill::VolunteerOrgBonus.new(log).revoke!(actor: verifier, reason:)
      end
    end
  end
end

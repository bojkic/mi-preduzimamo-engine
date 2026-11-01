# frozen_string_literal: true

require_relative "goodwill/volunteer_org_bonus"

module Decidim
  module Bih
    # Verifies dated completed work after approved participation and matching
    # attendance. The host's daily policy awards one base credit per person and
    # Sarajevo work date, while organization bonuses remain per eligible log.
    #
    # Returns :ok on success, :missing for a blank log, :already if the log was
    # already verified (approved), and :invalid for any other non-pending state.
    class VerifyVolunteerLog < ReviewDecision
      def self.call(log, verifier:, confirm_attendance: false)
        new(log, verifier:, confirm_attendance:).call
      end

      def initialize(log, verifier:, confirm_attendance: false)
        super()
        @log = log
        @verifier = verifier
        @confirm_attendance = confirm_attendance
      end

      private

      attr_reader :log, :verifier, :confirm_attendance

      def guards
        [
          [:missing, -> { log.blank? }],
          [:already, -> { log.approved? }],
          [:invalid, -> { !log.pending? }],
          [:invalid, -> { !log.respond_to?(:work_date) || log.work_date.blank? ||
                          log.worked_from_at.blank? || log.worked_until_at.blank? }]
        ]
      end

      def transaction_model
        Decidim::Bih::VolunteerLog
      end

      def review_record
        log
      end

      def run_transition
        result = :ok
        VolunteerLog.transaction do
          # This order matches application, cancellation and dated attendance:
          # opportunity, signup, work log, user and ledger resources.
          opportunity = VolunteerOpportunity.where(organization: log.organization).lock.find_by(id: log.opportunity.id)
          signup = opportunity&.signups&.lock&.find_by(user: log.user)
          if !opportunity || !approved_work_signup?(signup)
            result = :invalid
            raise ActiveRecord::Rollback
          end
          unless authorized_review?(opportunity) && (!confirm_attendance || attendance_authorized?(opportunity))
            result = :invalid
            raise ActiveRecord::Rollback
          end

          if confirm_attendance && !VolunteerAttendance.confirmed.exists?(
            organization: log.organization, opportunity:, user: log.user, work_date: log.work_date
          )
            result = ConfirmVolunteerAttendance.call(
              signup, confirmer: verifier, source: "operator", work_date: log.work_date
            ).status
            unless [:confirmed, :already].include?(result)
              result = :invalid
              raise ActiveRecord::Rollback
            end
          end

          log.lock!
          log.user.lock!
          result = run_guards || :ok
          result = :invalid unless result == :ok && dated_work_valid?(opportunity)
          raise ActiveRecord::Rollback unless result == :ok

          perform if result == :ok
          if confirm_attendance
            OperatorAuditEvent.record!(
              organization: log.organization, actor: verifier,
              event_type: "volunteer_log_verified", permission: "volunteering_hours_review",
              resource: log,
              metadata: { work_date: log.work_date.iso8601, attendance_confirmed_in_decision: true }
            )
          end
        end
        result
      end

      def dated_work_valid?(opportunity)
        return false unless log.work_date && log.worked_from_at && log.worked_until_at
        return false if log.worked_until_at > Time.current
        return false unless authorized_review?(opportunity)
        return false if confirm_attendance && !attendance_authorized?(opportunity)

        VolunteerAttendance.confirmed.exists?(
          organization: log.organization, opportunity:, user: log.user, work_date: log.work_date
        ) && log.valid?
      end

      def approved_work_signup?(signup)
        return false unless signup&.review_approved?
        return true if signup.going?

        signup.cancelled? && signup.participation_ended_at && log.worked_until_at &&
          log.worked_until_at < signup.participation_ended_at && log.work_date &&
          VolunteerAttendance.confirmed.exists?(
            organization: log.organization, opportunity: log.opportunity,
            user: log.user, work_date: log.work_date
          )
      end

      def authorized_review?(opportunity)
        verifier && verifier.organization == log.organization && verifier.id != log.user.id &&
          OperatorAuthorization.allowed?(
            verifier, :volunteering_hours_review, organization: log.organization, resource: opportunity
          )
      end

      def attendance_authorized?(opportunity)
        OperatorAuthorization.allowed?(
          verifier, :volunteering_attendance_confirm, organization: log.organization, resource: opportunity
        )
      end

      def perform
        log.update!(status: "approved", verifier:, verified_at: Time.current, rejection_reason: nil)
        Decidim::Bih::Goodwill::AwardDispatch.volunteer_log_verified(log)
        Decidim::Bih::Goodwill::VolunteerOrgBonus.call(log)
      end

      def notify
        VolunteerNotifications.publish(
          user: log.user,
          kind: :log,
          status: :approved,
          title: log.opportunity.title
        )
      end
    end
  end
end

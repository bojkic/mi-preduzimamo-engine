# frozen_string_literal: true

module Decidim
  module Bih
    # One administrator decision for one person/term, serialized by opportunity
    # before signup so concurrent approvals cannot allocate the last place twice.
    class ReviewVolunteerApplication
      Result = Struct.new(:status, :signup, :promoted_signups, keyword_init: true)

      class << self
        def call(signup, reviewer:, decision:, reason: nil, at: Time.current)
          return result(:missing) unless signup&.persisted?
          return result(:invalid, signup:) unless %w(approve reject).include?(decision.to_s)

          outcome = nil
          VolunteerOpportunity.transaction do
            opportunity = VolunteerOpportunity.lock.find_by(id: signup.decidim_bih_volunteer_opportunity_id)
            locked = VolunteerSignup.lock.find_by(id: signup.id)
            unless opportunity && locked && reviewer_eligible?(reviewer, locked, opportunity)
              outcome = result(:invalid, signup: locked || signup)
              next
            end
            unless locked.awaiting_review?
              outcome = result(:already, signup: locked)
              next
            end
            if opportunity.cancelled? || !opportunity.active? || cutoff_passed?(opportunity, locked, at)
              close!(locked, reason: opportunity.cancelled? ? "cancelled" : "decision_cutoff", at:)
              outcome = result(:closed, signup: locked)
              next
            end

            if decision.to_s == "reject"
              if reason.to_s.strip.blank? || locked.attendance_confirmed? || locked.dated_attendances.exists? ||
                 opportunity.logs.exists?(decidim_user_id: locked.decidim_user_id)
                outcome = result(:invalid, signup: locked)
                next
              end
              previous_status = locked.status
              locked.update!(status: "cancelled", review_status: "rejected", review_source: "admin",
                             reviewed_at: at, reviewer:, decision_reason: reason.to_s.strip, queued_at: nil,
                             participation_ended_at: at)
              audit!(locked, reviewer, "rejected", previous_status:)
              promoted = previous_status == "going" ? VolunteerSeatAllocator.promote!(opportunity, actor: reviewer) : []
              outcome = result(:rejected, signup: locked, promoted_signups: promoted)
            else
              previous_status = locked.status
              promoted = VolunteerSeatAllocator.promote!(opportunity, actor: reviewer)
              queued = opportunity.signups.approved_waitlist.exists?
              place = locked.going? || (!opportunity.full? && !queued)
              locked.update!(status: place ? "going" : "waitlisted", review_status: "approved",
                             review_source: "admin", reviewed_at: at, reviewer:, decision_reason: nil,
                             queued_at: place ? nil : (locked.queued_at || at))
              audit!(locked, reviewer, place ? "approved_place" : "approved_waitlist", previous_status:)
              outcome = result(place ? :approved_place : :approved_waitlist, signup: locked,
                               promoted_signups: promoted)
            end
          end
          notify(outcome)
          outcome
        end

        private

        def result(status, signup: nil, promoted_signups: [])
          Result.new(status:, signup:, promoted_signups:)
        end

        def reviewer_eligible?(reviewer, signup, opportunity)
          signup.decidim_organization_id == opportunity.decidim_organization_id &&
            OperatorAuthorization.allowed?(reviewer, :volunteering_application_review,
                                           organization: opportunity.organization, resource: signup)
        end

        def cutoff_passed?(opportunity, signup, at)
          return false if signup.review_source == "legacy_auto"

          cutoff = opportunity.decision_cutoff_for(signup)
          cutoff.present? && cutoff <= at
        end

        def close!(signup, reason:, at:)
          previous_status = signup.status
          signup.update!(status: "cancelled", review_status: "closed", review_source: "system",
                         reviewed_at: at, reviewer: nil, decision_reason: reason, queued_at: nil,
                         participation_ended_at: at)
          audit!(signup, nil, "closed", previous_status:)
        end

        def audit!(signup, actor, outcome, previous_status:)
          Decidim::Bih::OperatorAuditEvent.record!(
            organization: signup.organization, actor:, event_type: "volunteering_application_#{outcome}",
            permission: actor ? "volunteering_application_review" : nil, resource: signup,
            metadata: { opportunity_id: signup.decidim_bih_volunteer_opportunity_id,
                        previous_status:, outcome:, review_source: signup.review_source }
          )
        end

        def notify(outcome)
          return unless %i(approved_place approved_waitlist rejected closed).include?(outcome&.status)

          signup = outcome.signup
          reason = if outcome.status == :closed
                     I18n.t("decidim.bih.volunteer.index.application_closure_reasons.#{signup.decision_reason}",
                            default: signup.decision_reason)
                   else
                     signup.decision_reason
                   end
          Decidim::Bih::VolunteerNotifications.publish(
            user: signup.user, kind: "signup", status: outcome.status.to_s,
            title: signup.opportunity.title, reason:
          )
          outcome.promoted_signups.each do |promoted|
            Decidim::Bih::VolunteerNotifications.publish(
              user: promoted.user, kind: "signup", status: "promoted", title: promoted.opportunity.title
            )
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Closes undecided applications after the decision cutoff or cancellation.
    # Submission deadlines never close an application that arrived on time.
    class CloseVolunteerApplications
      Result = Struct.new(:closed, :expired_waitlist, keyword_init: true)

      def self.call(opportunity:, reason: "decision_cutoff", actor: nil, at: Time.current)
        return Result.new(closed: [], expired_waitlist: []) unless opportunity&.persisted?

        closed = []
        expired_waitlist = []
        VolunteerOpportunity.transaction do
          locked_opportunity = VolunteerOpportunity.lock.find(opportunity.id)
          locked_opportunity.signups.where(review_status: "pending", status: "pending").order(:id).each do |signup|
            next unless reason == "cancelled" || (locked_opportunity.decision_cutoff_for(signup)&.<= at)

            signup.lock!
            next unless signup.pending? && signup.awaiting_review?

            signup.update!(status: "cancelled", review_status: "closed", review_source: "system",
                           reviewed_at: at, reviewer: nil, decision_reason: reason,
                           participation_ended_at: at)
            OperatorAuditEvent.record!(
              organization: locked_opportunity.organization, actor:, event_type: "volunteering_application_closed",
              resource: signup, metadata: { opportunity_id: locked_opportunity.id, outcome: reason }
            )
            closed << signup
          end
          locked_opportunity.signups.approved_waitlist.order(:id).each do |signup|
            next unless reason == "cancelled" || (locked_opportunity.decision_cutoff_for(signup)&.<= at)

            signup.lock!
            next unless signup.waitlisted? && signup.review_approved?

            signup.update!(status: "cancelled", queued_at: nil, participation_ended_at: at,
                           decision_reason: reason == "cancelled" ? "cancelled" : "waitlist_expired")
            OperatorAuditEvent.record!(organization: locked_opportunity.organization, actor:,
                                       event_type: "volunteering_waitlist_expired", resource: signup,
                                       metadata: { opportunity_id: locked_opportunity.id, outcome: reason })
            expired_waitlist << signup
          end
        end
        closed.each do |signup|
          reason_text = I18n.t("decidim.bih.volunteer.index.application_closure_reasons.#{signup.decision_reason}",
                               default: signup.decision_reason)
          VolunteerNotifications.publish(user: signup.user, kind: "signup", status: "closed",
                                         title: signup.opportunity.title, reason: reason_text)
        end
        expired_waitlist.each do |signup|
          VolunteerNotifications.publish(user: signup.user, kind: "signup", status: "waitlist_expired",
                                         title: signup.opportunity.title, reason: signup.decision_reason)
        end
        Result.new(closed:, expired_waitlist:)
      end
    end
  end
end

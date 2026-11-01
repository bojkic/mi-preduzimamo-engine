# frozen_string_literal: true

module Decidim
  module Bih
    # Releases future participation when an opportunity is cancelled. Historical
    # attendance and claims stay in place for audited correction if needed.
    class CancelVolunteerApplications
      Result = Struct.new(:closed, :cancelled, keyword_init: true)

      def self.call(opportunity:, actor:, reason: "cancelled", at: Time.current, notify: true)
        return Result.new(closed: [], cancelled: []) unless opportunity&.persisted?
        raise ArgumentError, "not authorized" unless OperatorAuthorization.allowed?(
          actor, :volunteering_series_manage, organization: opportunity.organization, resource: opportunity
        )

        closed = []
        cancelled = []
        VolunteerOpportunity.transaction do
          locked_opportunity = VolunteerOpportunity.lock.find(opportunity.id)
          locked_opportunity.signups.order(:id).each do |signup|
            signup.lock!
            next if signup.cancelled? || signup.attendance_confirmed? || signup.dated_attendances.exists? ||
                    locked_opportunity.logs.exists?(decidim_user_id: signup.decidim_user_id)
            first_session = locked_opportunity.decision_cutoff_for(signup)
            next if signup.going? && first_session && first_session <= at

            if signup.awaiting_review?
              signup.update!(status: "cancelled", review_status: "closed", review_source: "system",
                             reviewed_at: at, reviewer: nil, decision_reason: reason.to_s.strip.presence || "cancelled",
                             queued_at: nil, participation_ended_at: at)
              closed << signup
            else
              signup.update!(status: "cancelled", queued_at: nil, participation_ended_at: at)
              cancelled << signup
            end
            OperatorAuditEvent.record!(organization: locked_opportunity.organization, actor:,
                                       event_type: "volunteering_application_cancelled_with_opportunity",
                                       resource: signup, metadata: { opportunity_id: locked_opportunity.id,
                                                                     review_status: signup.review_status })
          end
        end
        if notify
          (closed + cancelled).each do |signup|
            VolunteerNotifications.publish(user: signup.user, kind: "signup", status: "cancelled",
                                           title: signup.opportunity.title, reason: reason)
          end
        end
        Result.new(closed:, cancelled:)
      end
    end
  end
end

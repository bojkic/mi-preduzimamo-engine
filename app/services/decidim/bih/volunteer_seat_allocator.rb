# frozen_string_literal: true

module Decidim
  module Bih
    # Call while holding the opportunity row lock. A waiting episode receives a
    # stable queued_at; changing a signup later cannot move it to the front.
    class VolunteerSeatAllocator
      def self.promote!(opportunity, actor: nil)
        promoted = []
        return promoted unless opportunity.active? && !opportunity.cancelled?

        waiting = opportunity.signups.approved_waitlist.order(Arel.sql("queued_at ASC NULLS LAST"), :id)
        cutoff = Time.current
        waiting = if opportunity.starts_at
                    waiting.where("COALESCE(first_session_at, ?) > ?", opportunity.starts_at, cutoff)
                  else
                    waiting.where("first_session_at IS NULL OR first_session_at > ?", cutoff)
                  end
        available = opportunity.capacity.nil? ? waiting.count : [opportunity.capacity - opportunity.signups.going.count, 0].max
        waiting.limit(available).each do |signup|
          signup.lock!
          next unless signup.waitlisted? && signup.review_approved?

          signup.update!(status: "going", queued_at: nil)
          Decidim::Bih::OperatorAuditEvent.record!(
            organization: opportunity.organization, actor:, event_type: "volunteering_application_promoted",
            resource: signup, metadata: { opportunity_id: opportunity.id, outcome: "going" }
          )
          promoted << signup
        end
        promoted
      end
    end
  end
end

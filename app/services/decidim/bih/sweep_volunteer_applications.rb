# frozen_string_literal: true

module Decidim
  module Bih
    # Idempotent closure of due undecided applications. Approval also checks the
    # cutoff synchronously, so a late sweep can never allow late acceptance.
    class SweepVolunteerApplications
      def self.call(organization:, at: Time.current)
        raise ArgumentError, "organization required" unless organization&.persisted?
        return 0 unless Decidim::Bih.volunteer_application_review_required

        closed = 0
        queue = VolunteerSignup.where(organization:).where(
          "(status = 'pending' AND review_status = 'pending') OR " \
          "(status = 'waitlisted' AND review_status IN ('approved','automatic'))"
        )
        queue.distinct.pluck(:decidim_bih_volunteer_opportunity_id).each do |id|
          opportunity = VolunteerOpportunity.find_by(id:, organization:)
          next unless opportunity

          reason = opportunity.cancelled? ? "cancelled" : "decision_cutoff"
          result = CloseVolunteerApplications.call(opportunity:, reason:, at:)
          closed += result.closed.size + result.expired_waitlist.size
        end
        closed
      end
    end
  end
end

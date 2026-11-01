# frozen_string_literal: true

module Decidim
  module Bih
    # Controlled, organization-scoped cutover from automatic acceptance to first
    # human review. Run after old web/workers stop accepting applications, then
    # sweep again before enabling the host policy. Never changes seats, legacy
    # attendance, work claims, or points; never sends a notification burst.
    class ReconcileLegacyVolunteerApplications
      Preview = Struct.new(:candidates, :going, :waitlisted, :historical_attendance,
                           :already_pending_legacy, keyword_init: true)

      def self.preview(organization:)
        scope = VolunteerSignup.where(organization:)
        candidates = scope.where(review_status: "automatic", status: %w(going waitlisted))
        Preview.new(candidates: candidates.count, going: candidates.where(status: "going").count,
                    waitlisted: candidates.where(status: "waitlisted").count,
                    historical_attendance: candidates.where.not(attendance_confirmed_at: nil).count,
                    already_pending_legacy: scope.where(review_status: "pending", review_source: "legacy_auto",
                                                        status: %w(going waitlisted)).count)
      end

      def self.apply!(organization:, actor:)
        raise ArgumentError, "organization required" unless organization&.persisted?
        raise ArgumentError, "actor cannot review applications" unless OperatorAuthorization.allowed?(
          actor, :volunteering_application_review, organization:
        )

        converted = 0
        VolunteerOpportunity.where(organization:).order(:id).pluck(:id).each do |opportunity_id|
          VolunteerOpportunity.transaction do
            opportunity = VolunteerOpportunity.lock.find(opportunity_id)
            opportunity.signups.where(review_status: "automatic", status: %w(going waitlisted)).order(:id).each do |signup|
              signup.lock!
              next unless signup.review_status == "automatic" && %w(going waitlisted).include?(signup.status)

              signup.update!(review_status: "pending", review_source: "legacy_auto",
                             reviewed_at: nil, reviewer: nil, decision_reason: nil,
                             queued_at: signup.waitlisted? ? (signup.queued_at || signup.created_at) : nil)
              OperatorAuditEvent.record!(organization:, actor:, event_type: "volunteering_legacy_application_marked_for_review",
                                         resource: signup,
                                         metadata: { opportunity_id:, allocation: signup.status,
                                                     from_review_status: "automatic", to_review_status: "pending" })
              converted += 1
            end
          end
        end
        converted
      end
    end
  end
end

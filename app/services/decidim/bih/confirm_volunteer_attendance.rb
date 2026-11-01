# frozen_string_literal: true

module Decidim
  module Bih
    # Records attendance for a specific local work date. Both QR and operator
    # paths share the same locks and server-side eligibility checks.
    class ConfirmVolunteerAttendance
      Result = Struct.new(:status, :signup, :attendance, keyword_init: true)
      TIME_ZONE = "Europe/Sarajevo"

      class << self
        def call(signup, confirmer:, source: "operator", work_date: nil, status: "confirmed", at: Time.current)
          return Result.new(status: :missing) unless signup&.persisted?

          date = parse_work_date(work_date || at.in_time_zone(TIME_ZONE).to_date)
          return Result.new(status: :invalid, signup:) unless date && VolunteerAttendance::SOURCES.include?(source.to_s) &&
                                                             VolunteerAttendance::STATUSES.include?(status.to_s)
          return Result.new(status: :invalid, signup:) if source.to_s == "qr" && status.to_s == "absent"

          result = nil
          VolunteerOpportunity.transaction do
            opportunity = VolunteerOpportunity.lock.find_by(id: signup.decidim_bih_volunteer_opportunity_id)
            locked = VolunteerSignup.lock.find_by(id: signup.id)
            unless opportunity && locked && eligible?(locked, opportunity, confirmer, date, at)
              result = Result.new(status: :invalid, signup: locked || signup)
              next
            end

            attendance = VolunteerAttendance.find_by(opportunity:, user: locked.user, work_date: date)
            if attendance
              result = Result.new(status: attendance.status == status.to_s ? :already : :invalid,
                                  signup: locked, attendance:)
              next
            end

            attendance = VolunteerAttendance.create!(
              organization: locked.organization, opportunity:, signup: locked, user: locked.user,
              work_date: date, status: status.to_s, confirmed_at: at,
              confirmer:, source: source.to_s
            )
            OperatorAuditEvent.record!(
              organization: locked.organization, actor: confirmer,
              event_type: "volunteering_dated_attendance_#{status}",
              permission: "volunteering_attendance_confirm", resource: attendance,
              metadata: { opportunity_id: opportunity.id, work_date: date.iso8601,
                          status: status.to_s, source: source.to_s }
            )
            result = Result.new(status: status.to_sym, signup: locked, attendance:)
          end
          result
        end

        private

        def parse_work_date(value)
          return value if value.is_a?(Date) && !value.is_a?(DateTime)

          Date.iso8601(value.to_s)
        rescue Date::Error
          nil
        end

        def eligible?(signup, opportunity, confirmer, date, at)
          return false unless signup.going? && signup.review_approved?
          return false unless signup.decidim_organization_id == opportunity.decidim_organization_id
          return false unless OperatorAuthorization.allowed?(confirmer, :volunteering_attendance_confirm,
                                                             organization: opportunity.organization, resource: signup)
          return false unless opportunity.active? && opportunity.approved? && !opportunity.cancelled?
          return false if date > at.in_time_zone(TIME_ZONE).to_date
          return false if opportunity.starts_at && (opportunity.starts_at > at || date < opportunity.starts_at.in_time_zone(TIME_ZONE).to_date)
          return false if opportunity.ends_at && date > opportunity.ends_at.in_time_zone(TIME_ZONE).to_date
          return false if signup.first_session_at && date < signup.first_session_at.in_time_zone(TIME_ZONE).to_date
          return false if signup.first_session_at && signup.first_session_at > at

          true
        end
      end
    end
  end
end

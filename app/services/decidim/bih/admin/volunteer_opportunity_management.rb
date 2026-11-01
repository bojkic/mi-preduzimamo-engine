# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Admin
      # Auditable, scoped operator changes to an existing volunteering proposal.
      # The caller displays #preview and sends its token back with the command;
      # a concurrent change to a term or its participation makes the command stale.
      class VolunteerOpportunityManagement
        ACTIONS = %w(edit pause resume postpone cancel republish).freeze
        TIME_ZONE = "Europe/Sarajevo"
        SCOPES = %w(term future).freeze
        EDIT_FIELDS = %w(title meeting_point capacity category requirements starts_at ends_at signup_deadline_at).freeze
        Preview = Struct.new(:terms, :going, :waitlisted, :pending, :attendance, :logs, :token, keyword_init: true)
        Result = Struct.new(:status, :terms, :errors, :preview, :changes, keyword_init: true)

        def initialize(organization:, opportunity:, actor:, action:, scope: "term", attributes: {}, reason: nil, at: Time.current)
          @organization = organization
          @opportunity = opportunity
          @actor = actor
          @action = action.to_s
          @scope = scope.to_s
          @attributes = attributes.to_h.stringify_keys.slice(*EDIT_FIELDS, "shift_days")
          @reason = reason.to_s.strip
          @at = at
        end

        def preview
          terms = target_scope.includes(:signups, :logs).to_a
          snapshot(terms)
        end

        def call(expected_token:)
          return result(:invalid, ["invalid_action_or_scope"]) unless ACTIONS.include?(@action) && SCOPES.include?(@scope)
          return result(:invalid, ["reason_required"]) if %w(cancel republish).include?(@action) && @reason.blank?
          return result(:invalid, ["future_scope_requires_series"]) if @scope == "future" && @opportunity.series_key.blank?

          @cancelled_signups = []
          @participant_notices = []
          outcome = Decidim::Bih::VolunteerOpportunity.transaction do
            terms = target_scope.lock.to_a
            return result(:invalid, ["no_terms"]) if terms.empty?

            impact = snapshot(terms)
            return result(:stale, ["preview_changed"], preview: impact) unless ActiveSupport::SecurityUtils.secure_compare(impact.token, expected_token.to_s)

            error = validate_command(terms)
            return result(:invalid, [error], preview: impact) if error

            before = terms.map { |term| audit_state(term) }
            changed = execute!(terms)
            Result.new(status: :updated, terms: changed, errors: [], preview: impact,
                       changes: { before:, after: changed.map { |term| audit_state(term) } })
          end
          @cancelled_signups.each do |signup|
            Decidim::Bih::VolunteerNotifications.publish(
              user: signup.user, kind: "signup", status: "cancelled",
              title: signup.opportunity.title, reason: @reason
            )
          end if outcome.status == :updated
          @participant_notices.uniq { |signup, status, _detail| [signup.id, status] }.each do |signup, status, detail|
            Decidim::Bih::VolunteerNotifications.publish(
              user: signup.user, kind: "signup", status:, title: signup.opportunity.title, reason: detail
            )
          end if outcome.status == :updated
          outcome
        rescue ActiveRecord::RecordInvalid => e
          result(:invalid, e.record.errors.full_messages)
        end

        private

        def result(status, errors, preview: nil)
          Result.new(status:, terms: [], errors:, preview:)
        end

        def target_scope
          base = Decidim::Bih::VolunteerOpportunity.where(organization: @organization)
          return base.where(id: @opportunity.id) if @scope == "term"

          base.where(series_key: @opportunity.series_key)
              .where("starts_at IS NULL OR starts_at >= ?", @at).order(:starts_at, :id)
        end

        def snapshot(terms)
          ids = terms.map(&:id)
          signups = Decidim::Bih::VolunteerSignup.where(organization: @organization, decidim_bih_volunteer_opportunity_id: ids)
          logs = Decidim::Bih::VolunteerLog.where(organization: @organization, decidim_bih_volunteer_opportunity_id: ids)
          dated_attendance = Decidim::Bih::VolunteerAttendance.where(organization: @organization, decidim_bih_volunteer_opportunity_id: ids)
          signature = terms.map { |term| [term.id, term.updated_at.to_f, term.starts_at&.to_f, term.ends_at&.to_f, term.signup_deadline_at&.to_f, term.capacity, term.active, term.cancelled_at&.to_f] }
          signature << signups.order(:id).pluck(:id, :status, :review_status, :updated_at)
          signature << logs.order(:id).pluck(:id, :status, :updated_at)
          signature << dated_attendance.order(:id).pluck(:id, :status, :updated_at)
          Preview.new(
            terms: terms,
            going: signups.where(status: "going").count,
            waitlisted: signups.where(status: "waitlisted").count,
            pending: signups.where(review_status: "pending").count,
            attendance: signups.where.not(attendance_confirmed_at: nil).count + dated_attendance.count,
            logs: logs.count,
            token: Digest::SHA256.hexdigest(signature.inspect)
          )
        end

        def validate_command(terms)
          case @action
          when "edit", "postpone"
            return "future_scope_dates_not_supported" if @scope == "future" && @action == "edit" && (@attributes.keys & %w(starts_at ends_at signup_deadline_at)).any?
            return "invalid_capacity" if @action == "edit" && @attributes["capacity"].present? && Integer(@attributes["capacity"], exception: false).nil?
            return "protected_history" if terms.any? { |term| term.starts_at && term.starts_at <= @at || term.logs.exists? || term.signups.attendance_confirmed.exists? || term.dated_attendances.exists? }
            return "dates_required" if @action == "postpone" && terms.any? { |term| term.starts_at.nil? }
            return "dates_required" if @action == "edit" && @attributes.empty?
            return "shift_days_invalid" if @action == "postpone" && !(1..365).cover?(@attributes["shift_days"].to_i)
            if @action == "edit" && @attributes.key?("capacity")
              capacity = @attributes["capacity"].to_i
              return "capacity_below_places" if capacity.positive? && terms.any? { |term| term.signups.going.count > capacity }
            end
          when "republish"
            return "single_term_only" if terms.size != 1 || @scope != "term"
            return "must_be_inactive" if terms.first.active? && !terms.first.cancelled?
            return "dates_required" if @attributes["starts_at"].blank? || @attributes["ends_at"].blank?
          end
          nil
        end

        def execute!(terms)
          case @action
          when "edit"
            values = parsed_fields
            terms.each do |term|
              term.update!(values)
              if (term.saved_changes.keys & %w(starts_at ends_at signup_deadline_at meeting_point location)).any?
                collect_participant_notices(term, "schedule_changed")
              end
              if values.key?("capacity")
                Decidim::Bih::VolunteerSeatAllocator.promote!(term).each do |signup|
                  @participant_notices << [signup, "promoted", nil]
                end
              end
            end
          when "pause"
            terms.each { |term| term.update!(applications_paused_at: @at) }
          when "resume"
            terms.each { |term| term.update!(applications_paused_at: nil) unless term.cancelled? }
          when "postpone"
            days = @attributes["shift_days"].to_i
            terms.each do |term|
              term.update!(starts_at: shifted(term.starts_at, days), ends_at: shifted(term.ends_at, days),
                           signup_deadline_at: shifted(term.signup_deadline_at, days))
              term.signups.where.not(first_session_at: nil).find_each do |signup|
                signup.update!(first_session_at: shifted(signup.first_session_at, days))
              end
              collect_participant_notices(term, "postponed")
            end
          when "cancel"
            terms.each do |term|
              next if term.cancelled?

              term.update!(active: false, applications_paused_at: @at, cancelled_at: @at, canceller: @actor, cancellation_reason: @reason)
              outcome = Decidim::Bih::CancelVolunteerApplications.call(
                opportunity: term, reason: @reason, actor: @actor, at: @at, notify: false
              )
              @cancelled_signups.concat(outcome.closed + outcome.cancelled)
            end
          when "republish"
            old = terms.first
            fresh = old.dup
            fresh.assign_attributes(
              parsed_fields.slice("starts_at", "ends_at", "signup_deadline_at").symbolize_keys.merge(
                active: false, review_status: "pending", reviewed_at: nil, reviewer: nil, rejection_reason: nil,
                cancelled_at: nil, cancellation_reason: nil, canceller: nil, applications_paused_at: nil,
                partner_confirmed_at: nil, partner_confirmer: nil, proposal_identity: old.reward_proposal_identity,
                series_key: nil, series_position: nil, series_total: nil,
                org_bonus_awarded_points: 0
              )
            )
            fresh.save!
            return [fresh]
          end
          terms
        end

        def collect_participant_notices(term, status)
          term.signups.where(status: ["going", "waitlisted"]).includes(:user).each do |signup|
            @participant_notices << [signup, status, term.time_frame_label]
          end
        end

        def shifted(time, days)
          time&.in_time_zone(TIME_ZONE)&.advance(days:)
        end

        def audit_state(term)
          {
            id: term.id, title: term.title, starts_at: term.starts_at&.iso8601,
            ends_at: term.ends_at&.iso8601, signup_deadline_at: term.signup_deadline_at&.iso8601,
            capacity: term.capacity, active: term.active?,
            applications_paused_at: term.applications_paused_at&.iso8601,
            cancelled_at: term.cancelled_at&.iso8601, review_status: term.review_status
          }
        end

        def parsed_fields
          zone = ActiveSupport::TimeZone[TIME_ZONE]
          @attributes.each_with_object({}) do |(key, value), parsed|
            next if key == "shift_days"

            parsed[key] = if %w(starts_at ends_at signup_deadline_at).include?(key)
                            value.present? ? zone.parse(value.to_s) : nil
                          elsif key == "capacity"
                            value.present? ? Integer(value) : nil
                          else
                            value
                          end
          end
        end
      end
    end
  end
end

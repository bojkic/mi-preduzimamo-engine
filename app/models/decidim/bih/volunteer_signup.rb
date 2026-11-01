# frozen_string_literal: true

module Decidim
  module Bih
    # A signed-in citizen's RSVP to a volunteer opportunity. One row per
    # organization/opportunity/user (unique index), toggled between "going",
    # "waitlisted" and "cancelled" so re-signing up is idempotent.
    # Capacity is enforced against GOING signups only; waitlisted signups do not
    # occupy a seat, and cancelled signups free their seat. RSVP is intent to
    # attend only — it carries no goodwill points (logging verified hours does).
    class VolunteerSignup < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_volunteer_signups"

      STATUSES = %w(pending going waitlisted cancelled).freeze
      REVIEW_STATUSES = %w(pending approved automatic rejected closed).freeze
      REVIEW_SOURCES = %w(application admin automatic legacy_auto system).freeze
      ATTENDANCE_SOURCES = %w(operator qr).freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :opportunity,
                 class_name: "Decidim::Bih::VolunteerOpportunity",
                 foreign_key: "decidim_bih_volunteer_opportunity_id",
                 inverse_of: :signups

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id"

      belongs_to :attendance_confirmer,
                 class_name: "Decidim::User",
                 foreign_key: "attendance_confirmed_by_id",
                 optional: true

      belongs_to :reviewer, class_name: "Decidim::User", foreign_key: "reviewed_by_id", optional: true
      has_many :dated_attendances, class_name: "Decidim::Bih::VolunteerAttendance",
                                   foreign_key: "decidim_bih_volunteer_signup_id", dependent: :restrict_with_exception

      validates :status, inclusion: { in: STATUSES }
      validates :review_status, inclusion: { in: REVIEW_STATUSES }
      validates :review_source, inclusion: { in: REVIEW_SOURCES }
      validates :decision_reason, length: { maximum: 1_000 }, allow_blank: true
      validates :attendance_source, inclusion: { in: ATTENDANCE_SOURCES }, allow_blank: true
      validate :attendance_is_for_confirmed_signup
      validate :review_allocation_is_consistent
      validate :participation_end_is_consistent

      scope :pending, -> { where(status: "pending", review_status: "pending") }
      scope :going, -> { where(status: "going") }
      scope :waitlisted, -> { where(status: "waitlisted") }
      scope :approved_waitlist, -> { where(status: "waitlisted", review_status: %w(approved automatic)) }
      scope :cancelled, -> { where(status: "cancelled") }
      scope :active_rsvp, -> { where(status: %w(pending going waitlisted)) }
      scope :attendance_confirmed, -> { where.not(attendance_confirmed_at: nil) }

      def going?
        status == "going"
      end

      def pending?
        status == "pending"
      end

      def review_approved?
        %w(approved automatic).include?(review_status)
      end

      def awaiting_review?
        review_status == "pending" && !cancelled?
      end

      def waitlisted?
        status == "waitlisted"
      end

      def cancelled?
        status == "cancelled"
      end

      def active_rsvp?
        pending? || going? || waitlisted?
      end

      def attendance_confirmed?
        attendance_confirmed_at.present?
      end

      private

      def attendance_is_for_confirmed_signup
        return unless attendance_confirmed?

        errors.add(:status, :invalid) unless going?
        errors.add(:attendance_source, :blank) if attendance_source.blank?
        errors.add(:attendance_confirmer, :blank) if attendance_confirmer.blank?
      end

      def review_allocation_is_consistent
        if %w(rejected closed).include?(review_status) && !cancelled?
          errors.add(:status, :invalid)
        elsif pending? && review_status != "pending"
          errors.add(:review_status, :invalid)
        elsif (going? || waitlisted?) && !review_approved? && !(review_status == "pending" && review_source == "legacy_auto")
          errors.add(:review_status, :invalid)
        end
      end

      def participation_end_is_consistent
        errors.add(:participation_ended_at, :invalid) if cancelled? == participation_ended_at.nil?
      end
    end
  end
end

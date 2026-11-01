# frozen_string_literal: true

module Decidim
  module Bih
    # A citizen's logged volunteer hours against an opportunity. Starts "pending";
    # an org admin verifies it (see Decidim::Bih::VerifyVolunteerLog), which awards
    # goodwill points exactly once.
    class VolunteerLog < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_volunteer_logs"

      STATUSES = %w(pending approved rejected).freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :opportunity,
                 class_name: "Decidim::Bih::VolunteerOpportunity",
                 foreign_key: "decidim_bih_volunteer_opportunity_id",
                 inverse_of: :logs

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id"

      belongs_to :verifier,
                 class_name: "Decidim::User",
                 foreign_key: "verified_by_id",
                 optional: true

      # A dated claim is limited to one local work date. The interval is checked
      # against its actual elapsed duration, including daylight-saving changes.
      # A Sarajevo calendar date can span 25 elapsed hours when clocks go back.
      MAX_HOURS = 25

      validates :hours, numericality: { greater_than: 0, less_than_or_equal_to: MAX_HOURS }
      validates :status, inclusion: { in: STATUSES }
      validates :rejection_reason, length: { maximum: 1_000 }, allow_blank: true
      validate :same_organization
      validate :dated_interval_valid, unless: :undated_historical_record?
      validate :no_overlapping_work, if: -> { worked_from_at.present? && worked_until_at.present? && !rejected? }

      scope :pending, -> { where(status: "pending") }
      scope :approved, -> { where(status: "approved") }

      def pending?
        status == "pending"
      end

      def approved?
        status == "approved"
      end

      def rejected?
        status == "rejected"
      end

      private

      # Pre-cutover rows were never assigned a work date. Reading or updating an
      # existing approved row must not invent one, while every new claim and
      # every claim with any dated field must pass the interval checks.
      def undated_historical_record?
        return false unless persisted? && work_date.blank? && worked_from_at.blank? && worked_until_at.blank?

        rejected? || (approved? && !will_save_change_to_status?)
      end

      def same_organization
        errors.add(:opportunity, :invalid) if opportunity && opportunity.organization != organization
        errors.add(:user, :invalid) if user && user.organization != organization
      end

      def dated_interval_valid
        if work_date.blank? || worked_from_at.blank? || worked_until_at.blank?
          errors.add(:work_date, :blank)
          return
        end

        zone = Time.find_zone!("Europe/Sarajevo")
        local_start = worked_from_at.in_time_zone(zone)
        local_end = worked_until_at.in_time_zone(zone)
        unless local_start.to_date == work_date &&
               (local_end.to_date == work_date || (local_end.to_date == work_date.next_day &&
                 local_end.hour.zero? && local_end.min.zero? && local_end.sec.zero?))
          errors.add(:work_date, :invalid)
        end
        if worked_until_at <= worked_from_at || worked_until_at > Time.current
          errors.add(:worked_until_at, :invalid)
          return
        end

        if hours.present?
          duration = BigDecimal((worked_until_at - worked_from_at).to_s) / 3600
          errors.add(:hours, :invalid) unless duration.round(2) == BigDecimal(hours.to_s)
        end
        return unless opportunity

        errors.add(:worked_from_at, :invalid) if opportunity.starts_at && worked_from_at < opportunity.starts_at
        errors.add(:worked_until_at, :invalid) if opportunity.ends_at && worked_until_at > opportunity.ends_at
        errors.add(:worked_until_at, :invalid) if opportunity.cancelled_at && worked_until_at > opportunity.cancelled_at
      end

      def no_overlapping_work
        other = self.class.where(organization:, user:).where.not(status: "rejected")
        other = other.where.not(id:) if persisted?
        if other.where("worked_from_at < ? AND worked_until_at > ?", worked_until_at, worked_from_at).exists?
          errors.add(:worked_from_at, :taken)
        end
      end
    end
  end
end

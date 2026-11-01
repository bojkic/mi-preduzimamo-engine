# frozen_string_literal: true

module Decidim
  module Bih
    # A volunteer opportunity ("mission") an organization publishes for citizens
    # to log hours against. Citizen proposals start pending review; once an admin
    # approves one, it becomes active and the proposer earns goodwill points.
    class VolunteerOpportunity < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_volunteer_opportunities"

      REVIEW_STATUSES = %w(pending needs_revision approved rejected).freeze
      OPPORTUNITY_KINDS = %w(volunteer public_action).freeze
      ORG_BONUS_RECOGNITIONS = %w(
        attendance
        setup
        cleanup
        speaker_mentor
        logistics
        reporting
        mentoring
        other
      ).freeze
      SIGNUP_TIME_ZONE = "Europe/Sarajevo"

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :author,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_author_id",
                 optional: true

      belongs_to :reviewer,
                 class_name: "Decidim::User",
                 foreign_key: "reviewed_by_id",
                 optional: true

      belongs_to :partner_confirmer,
                 class_name: "Decidim::User",
                 foreign_key: "partner_confirmed_by_id",
                 optional: true

      belongs_to :canceller,
                 class_name: "Decidim::User",
                 foreign_key: "cancelled_by_id",
                 optional: true

      belongs_to :partner_profile,
                 class_name: "Decidim::Bih::PartnerProfile",
                 optional: true

      belongs_to :budget_project,
                 class_name: "Decidim::Budgets::Project",
                 foreign_key: "decidim_budgets_project_id",
                 optional: true

      belongs_to :komsiluk,
                 class_name: "Decidim::Bih::LocalArea",
                 optional: true

      has_many :logs,
               class_name: "Decidim::Bih::VolunteerLog",
               foreign_key: "decidim_bih_volunteer_opportunity_id",
               dependent: :restrict_with_exception,
               inverse_of: :opportunity

      has_many :signups,
               class_name: "Decidim::Bih::VolunteerSignup",
               foreign_key: "decidim_bih_volunteer_opportunity_id",
               dependent: :destroy,
               inverse_of: :opportunity

      has_many :dated_attendances, class_name: "Decidim::Bih::VolunteerAttendance",
                                   foreign_key: "decidim_bih_volunteer_opportunity_id", dependent: :restrict_with_exception

      before_validation :normalize_structured_fields

      validates :title, presence: true
      validates :opportunity_kind, presence: true, inclusion: { in: OPPORTUNITY_KINDS }
      validates :review_status, inclusion: { in: REVIEW_STATUSES }
      validates :rejection_reason, length: { maximum: 1_000 }, allow_blank: true
      # Bound the free-text fields: they carry PII under a 3-year retention window.
      validates :description, length: { maximum: 5_000 }, allow_blank: true
      validates :location, length: { maximum: 500 }, allow_blank: true
      validates :category, length: { maximum: 200 }, allow_blank: true
      validates :meeting_point, length: { maximum: 500 }, allow_blank: true
      validates :requirements, length: { maximum: 2_000 }, allow_blank: true
      validates :partner_name, length: { maximum: 200 }, allow_blank: true
      validates :cancellation_reason, length: { maximum: 1_000 }, allow_blank: true
      validates :series_key, length: { maximum: 64 }, allow_blank: true
      validates :proposal_identity, length: { maximum: 128 }, allow_blank: true
      validates :series_position,
                numericality: { only_integer: true, greater_than: 0 },
                allow_nil: true
      validates :series_total,
                numericality: { only_integer: true, greater_than: 0 },
                allow_nil: true
      validate :series_position_within_total
      # capacity is an optional sign-up cap; when present it must be a positive
      # whole number of volunteers.
      validates :capacity,
                numericality: { only_integer: true, greater_than: 0 },
                allow_nil: true
      validates :org_bonus_points_per_hour,
                numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :org_bonus_budget_cap,
                numericality: { only_integer: true, greater_than: 0 },
                allow_nil: true
      validates :org_bonus_max_participants,
                numericality: { only_integer: true, greater_than: 0 },
                allow_nil: true
      validates :org_bonus_awarded_points,
                numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :org_bonus_recognition,
                inclusion: { in: ORG_BONUS_RECOGNITIONS },
                allow_blank: true

      scope :active, -> { where(active: true, review_status: "approved") }
      scope :publicly_visible, lambda {
        active.where(partner_profile_id: nil).or(
          active.where(partner_profile_id: PartnerProfile.publicly_visible.select(:id))
        )
      }
      scope :pending_review, -> { where(active: false, review_status: "pending") }
      scope :upcoming, -> { where(starts_at: Time.current..).order(:starts_at) }

      validate :structured_area_is_a_komsiluk
      validate :partner_profile_belongs_to_organization
      validate :partner_profile_is_verified, if: :partner_profile_eligibility_validation_required?
      validate :partner_profile_is_volunteer_eligible, if: :partner_profile_eligibility_validation_required?
      validate :budget_project_belongs_to_organization
      validate :budget_project_is_approved_and_donation_enabled, if: :budget_project_link_validation_required?
      validate :partner_profile_required_for_public_submission
      validate :required_structured_proposal_fields
      validate :structured_keys_are_valid
      validate :simple_schedule_keys_are_valid
      validate :time_frame_is_valid
      validate :signup_deadline_is_valid

      def pending_review?
        review_status == "pending"
      end

      def public_action?
        opportunity_kind == "public_action"
      end

      def opportunity_kind_label
        I18n.t("decidim.bih.volunteer.opportunity_kinds.#{opportunity_kind}", default: opportunity_kind.to_s.humanize)
      end

      def approved?
        review_status == "approved"
      end

      def rejected?
        review_status == "rejected"
      end

      # Number of citizens currently committed to attend (GOING signups only).
      # Cancelled signups free their seat and are not counted.
      def signups_count
        signups.going.count
      end

      # An opportunity with a capacity is full once its GOING signups reach it.
      # No capacity means no cap, so it is never full.
      def full?
        return false if capacity.blank?

        signups_count >= capacity
      end

      def series?
        series_key.present? && series_total.to_i > 1
      end

      # Stable across terms and across a republication that copies the source's
      # proposal_identity. Existing rows are backfilled by the migration.
      def reward_proposal_identity
        proposal_identity.presence || (series_key.present? ? "series:#{series_key}" : "opportunity:#{id}")
      end

      def signup_deadline_passed?(at: Time.current)
        !Decidim::Bih::VolunteerSignupWindow.open?(deadline: signup_deadline_at, cancelled: false, at:)
      end

      def signup_open?(at: Time.current)
        return false if ends_at && ends_at <= at
        return false if starts_at && starts_at <= at && !rolling_programme?

        Decidim::Bih::VolunteerSignupWindow.open?(deadline: signup_deadline_at,
                                                  cancelled: cancelled?, paused: applications_paused_at.present?, at:)
      end

      def rolling_programme?
        starts_at && ends_at && ends_at - starts_at > 1.day
      end

      def decision_cutoff_for(signup)
        signup.first_session_at || starts_at
      end

      def signup_deadline_label
        return if signup_deadline_at.blank?

        I18n.l(signup_deadline_at.in_time_zone(SIGNUP_TIME_ZONE), format: :short)
      end

      def partner_confirmed?
        partner_confirmed_at.present?
      end

      def cancelled?
        cancelled_at.present?
      end

      def category_label
        Decidim::Bih::VolunteeringTaxonomy.category_label(category)
      end

      def location_label
        structured = komsiluk&.translated_name
        detail = meeting_point.presence || location.presence
        return [structured, detail].compact.join(" · ") if structured.present?

        detail.to_s
      end

      def time_frame_label
        return nil if starts_at.blank?

        starts = I18n.l(starts_at.in_time_zone(SIGNUP_TIME_ZONE), format: :short)
        return starts if ends_at.blank?

        "#{starts} - #{I18n.l(ends_at.in_time_zone(SIGNUP_TIME_ZONE), format: :short)}"
      end

      # Wall-clock hours in Sarajevo; elapsed UTC hours differ by one when a
      # programme crosses a daylight-saving change.
      def local_duration_hours
        return unless starts_at && ends_at

        local_start = starts_at.in_time_zone(SIGNUP_TIME_ZONE)
        local_end = ends_at.in_time_zone(SIGNUP_TIME_ZONE)
        ((ends_at - starts_at + local_end.utc_offset - local_start.utc_offset) / 1.hour).round(1)
      end

      def overlaps?(other)
        starts_at && ends_at && other.starts_at && other.ends_at &&
          starts_at < other.ends_at && other.starts_at < ends_at
      end

      def day_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:weekdays, day_keys)
      end

      def month_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:months, month_keys)
      end

      def time_slot_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:time_slots, time_slot_keys)
      end

      def schedule_label
        return time_frame_label if time_frame_label.present?

        [
          Decidim::Bih::VolunteeringTaxonomy.summary_for(:weekdays, day_keys, all_key: :all_days),
          Decidim::Bih::VolunteeringTaxonomy.summary_for(:months, month_keys, all_key: :all_months),
          Decidim::Bih::VolunteeringTaxonomy.summary_for(:time_slots, time_slot_keys, all_key: :all_time_slots)
        ].join(" · ")
      end

      def skill_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:skills, skill_keys)
      end

      def capability_labels
        Decidim::Bih::VolunteeringTaxonomy.labels_for(:capabilities, capability_keys)
      end

      def org_bonus_enabled?
        partner_profile.present? && org_bonus_points_per_hour.to_i.positive?
      end

      def org_bonus_remaining_points
        return nil if org_bonus_budget_cap.blank?

        [org_bonus_budget_cap.to_i - org_bonus_awarded_points.to_i, 0].max
      end

      def org_bonus_recognition_label
        return nil if org_bonus_recognition.blank?

        I18n.t(
          "decidim.bih.volunteer.org_bonus_recognitions.#{org_bonus_recognition}",
          default: org_bonus_recognition.to_s.humanize
        )
      end

      private

      def normalize_structured_fields
        self.category = category.to_s.strip.presence
        self.opportunity_kind = opportunity_kind.to_s.presence_in(OPPORTUNITY_KINDS) || "volunteer"
        self.location = location.to_s.strip.presence
        self.meeting_point = meeting_point.to_s.strip.presence
        self.requirements = requirements.to_s.strip.presence
        self.org_bonus_points_per_hour = org_bonus_points_per_hour.to_i
        self.org_bonus_budget_cap = org_bonus_budget_cap.to_i.positive? ? org_bonus_budget_cap.to_i : nil
        self.org_bonus_max_participants = org_bonus_max_participants.to_i.positive? ? org_bonus_max_participants.to_i : nil
        self.org_bonus_recognition = org_bonus_recognition.to_s.presence_in(ORG_BONUS_RECOGNITIONS)
        self.day_keys = normalized_keys_or_default(day_keys, :weekdays)
        self.month_keys = normalized_keys_or_default(month_keys, :months)
        self.time_slot_keys = normalized_keys_or_default(time_slot_keys, :time_slots)
        self.skill_keys = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(
          skill_keys,
          Decidim::Bih::VolunteeringTaxonomy::SKILLS
        )
        self.capability_keys = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(
          capability_keys,
          Decidim::Bih::VolunteeringTaxonomy::CAPABILITIES
        )
      end

      def normalized_keys_or_default(values, group)
        keys = Decidim::Bih::VolunteeringTaxonomy.sanitize_keys(
          values,
          Decidim::Bih::VolunteeringTaxonomy.default_keys(group)
        )
        keys.presence || Decidim::Bih::VolunteeringTaxonomy.default_keys(group)
      end

      def structured_area_is_a_komsiluk
        return if komsiluk.blank?

        errors.add(:komsiluk, :invalid) unless komsiluk.kind == "komsiluk"
        errors.add(:komsiluk, :invalid) unless komsiluk.decidim_organization_id == decidim_organization_id
      end

      def partner_profile_belongs_to_organization
        return if partner_profile.blank?

        errors.add(:partner_profile, :invalid) unless partner_profile.decidim_organization_id == decidim_organization_id
      end

      def partner_profile_is_verified
        return if partner_profile.blank?

        errors.add(:partner_profile, :unverified) unless partner_profile.verified?
      end

      def partner_profile_is_volunteer_eligible
        return if partner_profile.blank? || !partner_profile.verified?

        errors.add(:partner_profile, :invalid) unless partner_profile.volunteer_opportunity_eligible?
      end

      def budget_project_belongs_to_organization
        return if budget_project.blank?

        errors.add(:budget_project, :invalid) unless budget_project.organization == organization
      end

      def budget_project_is_approved_and_donation_enabled
        return if budget_project.blank? || organization.blank?

        linked = ProjectDonationLink.active.exists?(organization:, project: budget_project)
        submitted = partner_profile.present? && PartnerProjectSubmission.approved.exists?(
          organization:,
          partner_profile:,
          project: budget_project
        )
        errors.add(:budget_project, :invalid) unless linked && submitted
      end

      def partner_profile_eligibility_validation_required?
        new_record? || will_save_change_to_partner_profile_id?
      end

      def budget_project_link_validation_required?
        new_record? || will_save_change_to_partner_profile_id? || will_save_change_to_decidim_budgets_project_id?
      end

      def partner_profile_required_for_public_submission
        return unless citizen_pending_proposal?

        errors.add(:partner_profile, :blank) if partner_profile.blank?
      end

      def required_structured_proposal_fields
        return unless citizen_pending_proposal?

        errors.add(:category, :blank) if category.blank?
        errors.add(:category, :inclusion) if category.present? && Decidim::Bih::VolunteeringTaxonomy::CATEGORIES.exclude?(category)
        errors.add(:location, :blank) if location_or_komsiluk_required_for_proposals? && komsiluk.blank? && location.blank?
      end

      def structured_keys_are_valid
        errors.add(:skill_keys, :invalid) unless skill_keys.all? { |key| Decidim::Bih::VolunteeringTaxonomy::SKILLS.include?(key) }
        errors.add(:capability_keys, :invalid) unless capability_keys.all? { |key| Decidim::Bih::VolunteeringTaxonomy::CAPABILITIES.include?(key) }
      end

      def simple_schedule_keys_are_valid
        errors.add(:day_keys, :blank) if day_keys.blank?
        errors.add(:month_keys, :blank) if month_keys.blank?
        errors.add(:time_slot_keys, :blank) if time_slot_keys.blank?
      end

      def citizen_pending_proposal?
        decidim_author_id.present? && pending_review?
      end

      def location_or_komsiluk_required_for_proposals?
        Decidim::Bih::LocalArea.exists?(organization:)
      end

      def time_frame_is_valid
        return if starts_at.blank? || ends_at.blank?

        errors.add(:ends_at, :greater_than) unless ends_at > starts_at
      end

      def signup_deadline_is_valid
        return if signup_deadline_at.blank?

        errors.add(:signup_deadline_at, :invalid) if starts_at.blank?
        return if starts_at.blank?

        # A long programme can admit volunteers after its first day; each
        # application still has its own first-session decision cutoff.
        programme_window = ends_at.present? && ends_at - starts_at > 24.hours
        latest_cutoff = programme_window ? ends_at : starts_at
        return if signup_deadline_at < latest_cutoff

        errors.add(:signup_deadline_at, :invalid)
      end

      def series_position_within_total
        return if series_position.blank? || series_total.blank?
        return if series_position <= series_total

        errors.add(:series_position, :less_than_or_equal_to, count: series_total)
      end
    end
  end
end

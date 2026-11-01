# frozen_string_literal: true

module Decidim
  module Bih
    # Append-only, admin-visible event stream for report triage. Metadata must
    # stay PII-minimized: references/statuses/error classes/codes are fine;
    # citizen descriptions, addresses, contacts and internal note bodies are not.
    class ReportEvent < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_events"

      EVENT_TYPES = %w(
        case_agent_attempt case_agent_validation_failed case_agent_lease
        report_created
        case_dispatch_transport_unavailable case_dispatch_bounced
        city_email_received city_email_history_linked city_email_citizen_reply city_email_manually_linked
        case_dispatch_queued
        case_dispatch_cancelled
        case_dispatch_unknown
        case_dispatch_accepted
        case_dispatch_reconciled
        case_location_updated
        case_planning_updated
        case_collection_submitted
        case_decision_applied review_proposal_prepared review_proposal_requested
        case_reviewed
        case_message_created
        case_assignment_updated
        case_external_submission_recorded
        case_deadline_changed
        case_deadline_reminded
        case_second_reminder_prepared
        case_closure_proposed
        case_second_reminder_closed
        citizen_channel_message
        case_city_followup_automatic
        case_resolution_check_requested
        case_task_closed
        staff_alerts_created
        report_chat_confirmed
        report_chat_effects_dispatched
        processing_enqueued
        classification_updated
        status_changed
        internal_note_changed
        duplicate_marked
        duplicate_cleared
        forwarding_retry_enqueued
        forwarding_failed
        forwarding_failure_cleared
        forwarding_sent
        forwarding_held_for_review
        forwarding_reconciled
        sistem48_status_synced
      ).freeze
      SOURCES = %w(admin public background system).freeze
      FORBIDDEN_METADATA_KEYS = %w(
        address
        ai_summary
        contact
        coordinates
        description
        internal_note
        latitude
        longitude
        params
        payload
        photo_url
        reporter_contact
        reporter_email
        reporter_phone
        request_ip
        status_note
        user_agent
      ).freeze

      belongs_to :report,
                 class_name: "Decidim::Bih::Report",
                 foreign_key: "decidim_bih_report_id",
                 inverse_of: :events
      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"
      belongs_to :actor,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id",
                 optional: true

      validates :event_type, inclusion: { in: EVENT_TYPES }
      validates :source, inclusion: { in: SOURCES }
      validates :occurred_at, presence: true
      validate :same_organization_as_report
      validate :actor_same_organization

      before_validation :set_defaults
      before_validation :copy_organization_from_report
      after_create :record_goodwill_correction_intent
      before_update :prevent_mutation
      before_destroy :prevent_mutation

      scope :chronological, -> { order(:occurred_at, :id) }

      def self.available?
        connection.data_source_exists?(table_name)
      rescue StandardError
        false
      end

      def self.sanitize_metadata(metadata)
        metadata.to_h.each_with_object({}) do |(key, value), sanitized|
          key = key.to_s
          next if key.blank? || value.nil? || FORBIDDEN_METADATA_KEYS.include?(key)

          sanitized[key] = if key == "file_numbers"
                             Array(value).first(100).map { |number| number.to_s.first(120) }
                           else
                             sanitize_metadata_value(value)
                           end
        end
      end

      def self.sanitize_metadata_value(value)
        case value
        when Time, Date, ActiveSupport::TimeWithZone
          value.iso8601
        when TrueClass, FalseClass, Numeric
          value
        else
          value.to_s
        end
      end

      def actor_label
        return I18n.t("decidim.bih.admin.reports.events.system_actor", default: "System") unless actor

        actor.name.presence ||
          actor.nickname.presence ||
          I18n.t("decidim.bih.admin.reports.events.admin_actor", id: actor.id, default: "Admin #%{id}")
      end

      private

      def record_goodwill_correction_intent
        return unless %w(report_created case_decision_applied duplicate_marked duplicate_cleared status_changed
                         case_second_reminder_closed).include?(event_type)

        Decidim::Bih::Goodwill::CorrectionIntent.create!(report_event: self, report:,
                                                         decision_version: Goodwill::SourceCreditCorrection.outcome_version_for(report),
                                                         target_amount: Goodwill::ReportEntitlement.outcome_target(report))
      end

      def set_defaults
        self.occurred_at ||= Time.current
        self.source ||= actor ? "admin" : "system"
        self.actor_role ||= actor ? "admin" : source
      end

      def copy_organization_from_report
        self.organization ||= report&.organization
      end

      def same_organization_as_report
        return unless report && organization
        return if report.decidim_organization_id == organization.id

        errors.add(:decidim_organization_id, :invalid)
      end

      def actor_same_organization
        return unless actor && organization
        return if actor.decidim_organization_id == organization.id

        errors.add(:decidim_user_id, :invalid)
      end

      def prevent_mutation
        raise ActiveRecord::ReadOnlyRecord, "report events are append-only"
      end
    end
  end
end

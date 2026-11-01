# frozen_string_literal: true

module Decidim
  module Bih
    class ReportCollectionWorkflow
      def initialize(collection, actor)
        @collection = collection
        @actor = actor
      end

      def update(attributes)
        authorize!(:reports_update_status)
        @collection.with_lock do
          fail_with(:sent_locked) unless @collection.draft?
          values = attributes.to_h.symbolize_keys
          owner = ReportCaseWorkflow.staff(@collection.organization).find_by(id: values[:assigned_to_id])
          due = values[:review_due_at].present? && Time.zone.parse(values[:review_due_at])
          fail_with(:owner_due_required) unless owner && due && due > Time.current
          @collection.update!(values.slice(:title, :topic, :summary).merge(assigned_to: owner, review_due_at: due, state: "collecting"))
          update_members(owner, due)
          audit("collection_updated", :reports_update_status)
        end
      rescue ArgumentError
        fail_with(:owner_due_required)
      end

      def ready
        authorize!(:reports_update_status)
        @collection.with_lock do
          fail_with(:sent_locked) unless @collection.draft?
          reports = @collection.reports.order(:id).lock.to_a
          fail_with(:not_ready) if reports.empty? || @collection.summary.blank? || reports.any? do |r|
            r.review_state != "validated" || !submission_location?(r) || r.forwarding_note.blank? || !r.planned?
          end
          @collection.update!(state: "ready", submission_snapshot: @collection.submission_text)
          audit("collection_ready", :reports_update_status)
        end
      end

      # Explicit receipt recording only. This action never sends mail.
      def record_submission(recipient:, reference:, confirmed:)
        authorize!(:reports_retry_forwarding)
        @collection.with_lock do
          validate_receipt!(recipient, reference, confirmed)
          reports = @collection.reports.order(:id).lock.to_a
          validate_snapshot!(reports)
          @collection.update!(state: "submitted", recipient: recipient.to_s.strip, external_reference: reference.to_s.strip, submitted_at: Time.current)
          reports.each do |report|
            report.update!(status: "proslijedjeno", forwarded_at: @collection.submitted_at, external_submission_reference: reference.to_s.strip,
                           deadline_kind: "city", response_due_at: @collection.submitted_at + ReportWorkQueue::CITY_DAYS.days)
            report.record_event!("case_collection_submitted", actor: @actor, metadata: { collection_id: @collection.id, status: report.status })
          end
          audit("collection_submission_recorded", :reports_retry_forwarding)
        end
      end

      private

      def submission_location?(report)
        report.address.present? || report.report_subtype == "opsti_prijedlog"
      end

      def update_members(owner, due)
        @collection.reports.order(:id).each do |report|
          report.with_lock do
            # A new citizen reply/question has its own deadline. Updating the
            # collection must not erase that outstanding individual work.
            if report.review_state == "validated" && report.planned?
              report.update!(assigned_to: owner, response_due_at: due, deadline_kind: "planning")
            else
              report.update!(assigned_to: owner)
            end
          end
        end
      end

      def validate_receipt!(recipient, reference, confirmed)
        fail_with(:confirm_required) unless confirmed == "1"
        fail_with(:not_ready) unless @collection.state == "ready" && @collection.submitted_at.nil?
        fail_with(:receipt_required) if [recipient, reference].any? { |value| value.to_s.strip.blank? || value.to_s.length > 240 }
      end

      def validate_snapshot!(reports)
        fail_with(:not_ready) if reports.empty? || reports.any? { |r| !r.planned? || r.forwarded_at || r.review_state != "validated" }
        fail_with(:not_ready) unless @collection.submission_snapshot == @collection.submission_text
      end

      def authorize!(permission)
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(@actor, permission, organization: @collection.organization)
      end

      def audit(event, permission)
        OperatorAuditEvent.record!(organization: @collection.organization, actor: @actor, event_type: event, permission: permission,
                                   resource: @collection, metadata: { state: @collection.state, report_count: @collection.reports.count })
      end

      def fail_with(key)
        raise ReportPlanning::Invalid, I18n.t("decidim.bih.report_planning.errors.#{key}")
      end
    end
  end
end

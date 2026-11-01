# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    class ReportCaseWorkflow
      class Invalid < StandardError; end

      def self.staff(organization)
        roles = OperatorRole.active.where(organization:).for_permission(:reports_read).select(:decidim_user_id)
        users = Decidim::User.where(organization:, blocked: false, deleted_at: nil)
        users.where(admin: true).or(users.where(id: roles))
      end

      def self.recipients(organization)
        ([Sistem48::DepartmentRouting.central_intake(organization)] +
          ReportTaxonomy::CATEGORIES.map { |category| Sistem48::DepartmentRouting.email_for(category, organization) })
          .compact_blank.uniq.grep(URI::MailTo::EMAIL_REGEXP)
      end

      def self.digest(report)
        Digest::SHA256.hexdigest(report.to_forwarder_hash.except(:photo_url).merge(
          report_id: report.id, reviewed_at: report.reviewed_at, review_state: report.review_state,
          status: report.status, photo_blob_id: report.photo.blob&.id,
          last_citizen_message_id: report.case_messages.where(actor_role: "citizen").maximum(:id),
          reply_photos: report.case_messages.with_attached_photo.order(:id).map do |message|
            [message.id, message.photo.attached? ? message.photo.blob.checksum : nil,
             message.respond_to?(:files) ? message.files.order(:id).map { |file| file.blob.checksum } : []]
          end,
          location_kind: report.location_kind, location_end_latitude: report.location_end_latitude,
          location_end_longitude: report.location_end_longitude
        ).to_json)
      end

      def initialize(report, actor)
        @report = report
        @actor = actor
      end

      def update(attributes)
        authorize!(:reports_update_status)
        values = attributes.to_h.symbolize_keys
        notice = nil
        report.with_lock do
          previous_decision = report.review_state
          protect_sent_details!(values)
          owner = review_owner(values)
          recipient = review_recipient(values)
          decision = review_decision(values, recipient)
          due = values[:response_due_at].present? ? Time.zone.parse(values[:response_due_at].to_s) : nil
          report.update!(values.slice(:category, :department, :severity, :resolution_evidence, :status_note, :forwarding_note).merge(
                           assigned_to: owner, response_due_at: due, review_state: decision,
                           forwarding_recipient: recipient.presence, reviewed_by: actor, reviewed_at: Time.current,
                           last_reviewed_message_id: report.case_messages.where(actor_role: "citizen").maximum(:id),
                           review_pending_since: decision == "pending" ? (report.review_pending_since || Time.current) : nil
                         ))
          report.update!(status: "odbijeno") if decision == "rejected"
          notice = rejection_notice if decision == "rejected" && previous_decision != decision
          record_staff_event("case_reviewed", permission: :reports_update_status,
                                              metadata: { review_state: decision, assigned: owner.present?, due_at: due, reviewed_message_id: report.last_reviewed_message_id })
        end
        enqueue_message(notice) if notice
      rescue ArgumentError
        fail_with(:invalid_due)
      end

      def message(body:, question: false, response_due_at: nil)
        authorize!(:reports_update_status)
        result = nil
        report.with_lock do
          fail_with(:terminal) if Report::TERMINAL_STATUSES.include?(report.status)
          due = response_due_at.present? ? Time.zone.parse(response_due_at.to_s) : report.response_due_at
          fail_with(:invalid_due) if question && (due.nil? || due <= Time.current)
          result = report.case_messages.create!(actor:, actor_role: "staff", kind: question ? "question" : "update", body: body.to_s.strip)
          report.update!(review_state: "needs_information", response_due_at: due, deadline_kind: "citizen", review_pending_since: nil) if question
          record_message(result)
        end
        enqueue_message(result)
        result
      rescue ArgumentError
        fail_with(:invalid_due)
      end

      def reply(body:, feedback: nil, photo: nil, files: [], answers_message_id: nil)
        # The controller must verify the private bearer link and tenant first.
        normalized = ReportEvidence.normalize(photo)
        result = nil
        report.with_lock do
          if feedback.present?
            fail_with(:not_resolved) unless report.status == "rijeseno"
            fail_with(:invalid_feedback) unless %w(accepted problem_persists).include?(feedback)
            report.update!(resident_feedback: feedback)
            report.update!(status: "u_obradi", review_state: "pending") if feedback == "problem_persists"
          end
          result = report.case_messages.new(actor:, actor_role: "citizen", kind: feedback.present? ? "feedback" : "reply", body: body.to_s.strip)
          result.answers_message = report.case_messages.where(kind: "question", actor_role: "staff").find(answers_message_id) if answers_message_id.present?
          attach_reply_evidence!(result, files, normalized)
          result.save!
          report.update!(last_citizen_reply_at: result.created_at)
          fulfil_explicit_question!(result)
          ReportSecondReminders.reopen_after_reply!(report, message: result)
          if pending_review_after_reply?
            report.update!(review_state: "pending", review_pending_since: result.created_at,
                           response_due_at: result.created_at + ReportWorkQueue::REVIEW_DAYS.days, deadline_kind: "review")
          end
          record_message(result)
        end
        enqueue_message(result)
        ReportReviewAssistant.enqueue(report)
        result
      ensure
        normalized[:io].close! if normalized
      end

      def record_external(reference:)
        authorize!(:reports_retry_forwarding)
        report.with_lock do
          fail_with(:already_forwarded) if report.collective? || report.planned?
          fail_with(:not_validated) unless report.review_state == "validated"
          fail_with(:already_forwarded) if report.forwarded_at.present?
          fail_with(:external_reference) if reference.to_s.strip.blank? || reference.to_s.length > 240
          report.update!(external_submission_reference: reference.to_s.strip, forwarded_at: Time.current, status: "proslijedjeno")
          record_staff_event("case_external_submission_recorded", permission: :reports_retry_forwarding, metadata: { status: report.status })
        end
      end

      private

      def attach_reply_evidence!(message, files, normalized)
        validated_files = ReportMailbox::CitizenReply.validated_files(files)
        message.files.attach(validated_files) if validated_files.any?
        message.photo.attach(normalized) if normalized
      end

      def fulfil_explicit_question!(message)
        return unless message.answers_message_id && ReportObligation.available?

        answered = ReportObligations.answered_by(report, message)
        ReportObligations.fulfil!(answered, by: message) if answered.is_a?(ReportObligation)
      end

      attr_reader :report, :actor

      def rejection_notice
        body = report.duplicate? ? ReportStatusPresenter.duplicate_message(report) : report.status_note
        message = report.case_messages.create!(actor:, actor_role: "staff", kind: "update", body:, notified_at: Time.current, notification_state: "status_notice")
        record_message(message)
        message
      end

      def protect_sent_details!(values)
        changed = [:category, :department, :severity, :forwarding_recipient, :forwarding_note].any? do |key|
          values.has_key?(key) && values[key].to_s != report.public_send(key).to_s
        end
        fail_with(:already_forwarded) if report.forwarded_at.present? && changed
      end

      def review_owner(values)
        owner = values[:assigned_to_id].presence && self.class.staff(report.organization).find_by(id: values[:assigned_to_id])
        fail_with(:invalid_owner) if values[:assigned_to_id].present? && owner.nil?
        owner
      end

      def review_recipient(values)
        recipient = values[:forwarding_recipient].to_s.strip
        fail_with(:invalid_recipient) if recipient.present? && self.class.recipients(report.organization).exclude?(recipient)
        recipient
      end

      def review_decision(values, recipient)
        decision = values[:review_state].to_s
        fail_with(:invalid_decision) unless Report::REVIEW_STATES.include?(decision)
        validate_waiting_decision!(decision)
        fail_with(:confirm_review) if %w(validated rejected).include?(decision) && values[:confirm_review] != "1"
        fail_with(:rejection_reason) if decision == "rejected" && values[:status_note].to_s.strip.blank?
        fail_with(:invalid_recipient) if decision == "validated" && !valid_review_recipient?(values, recipient)
        decision
      end

      def pending_review_after_reply?
        Report::TERMINAL_STATUSES.exclude?(report.status)
      end

      def valid_review_recipient?(values, recipient)
        values[:category].present? && (recipient.present? || report.collective?)
      end

      def validate_waiting_decision!(decision)
        fail_with(:invalid_decision) if decision == "needs_information" && report.review_state != "needs_information"
      end

      def authorize!(permission)
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(actor, permission, organization: report.organization)
      end

      def fail_with(key)
        raise Invalid, I18n.t("decidim.bih.report_case.errors.#{key}")
      end

      def record_staff_event(event_type, permission:, metadata:)
        report.record_event!(event_type, actor:, metadata:)
        OperatorAuditEvent.record!(organization: report.organization, actor:, event_type:, permission: permission.to_s,
                                   role: OperatorAuthorization.role_for(actor, permission, organization: report.organization),
                                   resource: report, metadata:)
      end

      def record_message(message)
        if message.actor_role == "staff"
          return record_staff_event("case_message_created", permission: :reports_update_status,
                                                            metadata: { message_id: message.id, kind: message.kind })
        end

        report.record_event!("case_message_created", actor:, actor_role: message.actor_role,
                                                     source: message.actor_role == "staff" ? "admin" : "public",
                                                     metadata: { message_id: message.id, kind: message.kind })
      end

      def enqueue_message(message)
        return if message.notified_at

        ActiveRecord.after_all_transactions_commit do
          ReportCaseMessageJob.perform_later(message.id)
        rescue StandardError => e
          Rails.logger.error("[ReportCaseWorkflow] message notification pending id=#{message.id} error=#{e.class}")
        end
      end
    end
  end
end

# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- explicit independent policy and safety guards

module Decidim
  module Bih
    # Shared, version-checked command entry for single and batch review. No AI
    # output can call this without an authenticated, authorized human approval.
    class ReportDecision
      class Invalid < StandardError; end
      ACTIONS = %w(save_draft claim assign note message service_response ask send supplement followup plan unplan reject duplicate resolve reopen external review).freeze
      AI_DECISION_ACTIONS = %w(send ask duplicate plan review reject supplement followup resolve reopen).freeze
      SEND_ACTIONS = %w(send supplement followup).freeze
      REASONS = %w(reject resolve reopen).freeze
      PERMISSIONS = { "note" => :reports_internal_note, "service_response" => :reports_internal_note, "duplicate" => :reports_mark_duplicate,
                      "send" => :reports_retry_forwarding, "supplement" => :reports_retry_forwarding,
                      "followup" => :reports_retry_forwarding, "external" => :reports_retry_forwarding }.freeze
      EDIT_FIELDS = [:category, :severity, :forwarding_note, :forwarding_recipient].freeze
      FIELDS = (EDIT_FIELDS + [:ai_proposal_id, :draft_action, :department, :assigned_to_id, :response_due_at, :body, :reason, :resolution_evidence,
                               :duplicate_reference, :report_collection_id, :report_subtype, :collection_title, :collection_topic,
                               :collection_summary, :external_reference, :address, :location_kind, :latitude, :longitude,
                               :location_end_latitude, :location_end_longitude, :edit_location, :closure_basis, :no_reply_outcome]).freeze

      # Potential notifications, subject to the actual status transition and
      # recipient eligibility. Supplements and reminders do not change status.
      NOTIFICATION_ACTIONS = {
        "send external plan unplan reject duplicate resolve reopen" => %w(report.reporter_status_email report.author_external_copy),
        "ask message" => %w(report.case_message_to_author)
      }.freeze

      def self.notification_consequences(action)
        keys = NOTIFICATION_ACTIONS.find { |actions, _| actions.split.include?(action.to_s) }&.last || []
        Messaging::SendConsequences.tolerant_for(keys)
      end

      def initialize(report, actor, approval_key: nil)
        @approval_key = approval_key
        @report = report
        @actor = actor
      end

      def self.allowed_actions(report)
        common = %w(save_draft claim assign note)
        return common + ["reopen"] if Report::TERMINAL_STATUSES.include?(report.status)
        return common + ["message"] if report.dispatches.exists?(state: %w(queued sending unknown))

        actions = common + %w(message ask review)
        if report.forwarded_at
          actions + %w(service_response supplement followup resolve reject)
        elsif report.collective?
          actions + %w(plan unplan)
        else
          actions + %w(send external plan duplicate reject resolve)
        end
      end

      def call(action:, values:, version:, confirmed: false, approved_mail_digest: nil)
        @approved_mail_digest = approved_mail_digest
        @action = action.to_s
        fail_with(:invalid_action) unless ACTIONS.include?(@action)
        authorize!(:reports_update_status) unless @action == "note"
        authorize!(PERMISSIONS.fetch(@action, :reports_update_status))
        @values = values.to_h.symbolize_keys.slice(*FIELDS)
        [:category, :severity].each { |key| @values[key] = @values[key].presence if @values.has_key?(key) }
        fail_with(:too_large) if @values.to_json.bytesize > 24_000
        result = nil
        ensure_reply_capability!
        with_case_locks do
          fail_with(:stale) if @approval_key && report.events.where(event_type: "case_decision_applied").exists?(["metadata ->> 'approval_key' = ?", @approval_key])
          validate_command!(version, confirmed)
          validate_ai_proposal!
          result = perform
          report.update!(review_draft: {}) unless %w(save_draft claim assign note message).include?(@action)
          audit!
        end
        result.is_a?(ReportDispatch) ? result : report
      end

      # Compute the exact outgoing content without approving or changing data.
      # All temporary edits roll back; the caller signs this digest together with
      # the actor, input version and values before rendering the confirmation.
      def preview(action:, values:, version:)
        @action = action.to_s
        fail_with(:invalid_action) unless SEND_ACTIONS.include?(@action)
        authorize!(:reports_update_status)
        authorize!(:reports_retry_forwarding)
        @values = values.to_h.symbolize_keys.slice(*FIELDS)
        [:category, :severity].each { |key| @values[key] = @values[key].presence if @values.has_key?(key) }
        fail_with(:too_large) if @values.to_json.bytesize > 24_000
        snapshot = nil
        ensure_reply_capability!
        with_case_locks do
          fail_with(:stale) unless version.to_s == ReportReviewVersion.digest(report)
          fail_with(:not_ready) unless self.class.allowed_actions(report).include?(@action)
          validate_ai_proposal!
          review
          fail_with(:location_required) if @action == "send" && report.address.blank? && (report.latitude.nil? || report.longitude.nil?)
          mail = ReportDispatching.preview(report:, kind: @action == "send" ? "initial" : @action, text: @values[:body])
          snapshot = ReportEvidence.snapshot(mail).merge(digest: ReportDispatching.mail_digest(mail))
          snapshot[:attachments] = snapshot[:attachments].map { |item| item.except(:content) }
          raise ActiveRecord::Rollback
        end
        snapshot
      ensure
        report.reload
      end

      private

      attr_reader :report, :actor, :values, :action

      def ensure_reply_capability!
        return unless SEND_ACTIONS.include?(@action)

        recipient = @values[:forwarding_recipient].presence || report.forwarding_recipient.presence || Sistem48::DepartmentRouting.email_for(
          @values[:category].presence || report.category, report.organization
        )
        ReportMailbox::ReplyAddress.ensure!(report:, audience: "service", correspondents: [recipient])
      end

      # Collections precede members (same order as ReportPlanning). Duplicate
      # pairs are locked by ID, so opposite simultaneous joins cannot cycle.
      def with_case_locks
        expected_collection = report.report_collection_id
        ids = [expected_collection, values[:report_collection_id].presence].compact
        target = values[:duplicate_reference].presence && Report.find_by(organization: report.organization, reference: values[:duplicate_reference])
        Report.transaction do
          ReportCollection.where(organization: report.organization, id: ids).order(:id).lock.load
          Report.where(organization: report.organization, id: [report.id, target&.id].compact).order(:id).lock.load
          report.reload
          fail_with(:stale) unless report.report_collection_id == expected_collection
          yield
        end
      end

      HANDLERS = { "save_draft" => :save_draft, "claim" => :claim, "assign" => :assign, "note" => :save_note,
                   "message" => :message, "ask" => :ask, "send" => :send_to_service, "supplement" => :send_to_service,
                   "followup" => :send_to_service, "plan" => :plan, "unplan" => :unplan, "reject" => :settle,
                   "resolve" => :settle, "reopen" => :settle, "duplicate" => :duplicate, "external" => :external,
                   "review" => :review, "service_response" => :service_response }.freeze

      def validate_command!(version, confirmed)
        fail_with(:stale) unless version.to_s == ReportReviewVersion.digest(report)
        fail_with(:not_ready) unless self.class.allowed_actions(report).include?(@action)
        fail_with(:confirmation) unless confirmed == true || %w(save_draft claim assign note).include?(@action)
      end

      def perform = __send__(HANDLERS.fetch(action))

      def save_draft
        report.update!(review_draft: { values: values, actor_id: actor.id, saved_at: Time.current.iso8601(6) })
      end

      def claim = report.update!(assigned_to: actor)

      def assign = report.update!(assigned_to: owner)

      # A notice to the citizen on a case reviewed before (e.g. after recording a
      # City answer) completes that review; the stored City task keeps the clock.
      def message
        workflow.message(body: required_text(:body))
        return unless report.reload.review_state == "pending" && report.reviewed_at.present?

        report.update!(reviewed_attributes.merge(review_state: "validated", response_due_at: nil, deadline_kind: nil))
      end

      def workflow = ReportCaseWorkflow.new(report, actor)

      def owner
        return report.assigned_to || actor unless values.has_key?(:assigned_to_id)
        return nil if values[:assigned_to_id].blank?

        ReportCaseWorkflow.staff(report.organization).find_by(id: values[:assigned_to_id]) || fail_with(:invalid_owner)
      end

      def planning_due
        values[:response_due_at].present? ? due(0) : ReportPlanning.default_review_due_at
      end

      def due(days)
        time = values[:response_due_at].present? ? Time.zone.parse(values[:response_due_at].to_s) : days.days.from_now
        fail_with(:invalid_due) unless time && time > Time.current
        time
      rescue ArgumentError
        fail_with(:invalid_due)
      end

      def required_text(key, limit: 3000)
        text = values[key].to_s.strip
        fail_with(:text_required) if text.blank? || text.length > limit
        text
      end

      def save_note
        text = required_text(:body)
        report.update!(internal_note: [report.internal_note.presence, "#{actor.name} · #{Time.current.iso8601}\n#{text}"].compact.join("\n\n"))
        report.record_event!("internal_note_changed", actor:, metadata: { current_note_present: true })
      end

      # Inbound evidence is private. Recording it does not send a question or
      # start a citizen deadline. References remain a group, never an inferred mapping.
      def service_response
        reference = values[:external_reference].to_s.strip
        fail_with(:too_large) if reference.length > 1000
        text = [I18n.t("decidim.bih.report_evidence.service_response"), reference.presence, required_text(:body)].compact.join("\n")
        report.update!(internal_note: [report.internal_note.presence, "#{actor.name} · #{Time.current.iso8601}\n#{text}"].compact.join("\n\n"),
                       review_state: "pending", review_pending_since: Time.current, assigned_to: owner,
                       response_due_at: due(ReportWorkQueue::REVIEW_DAYS), deadline_kind: "review")
        report.record_event!("internal_note_changed", actor:, metadata: { service_response: true, references_grouped: reference.present? })
        ReportReviewAssistant.enqueue(report)
      end

      def reviewed_attributes
        { reviewed_by: actor, reviewed_at: Time.current, review_pending_since: nil,
          last_reviewed_message_id: report.case_messages.where(actor_role: "citizen").maximum(:id), assigned_to: owner }
      end

      def edit_details
        return protect_sent_details! if report.forwarded_at

        if values[:edit_location] == "1"
          ReportPlanning.new(report, actor).location(values.slice(:address, :location_kind, :latitude, :longitude, :location_end_latitude, :location_end_longitude))
        end
        report.update!(edited_attributes)
      end

      def protect_sent_details!
        changed = EDIT_FIELDS.any? { |key| values.has_key?(key) && values[key].to_s != report.public_send(key).to_s }
        fail_with(:sent_locked) if changed || values[:edit_location] == "1"
      end

      def edited_attributes
        attributes = values.slice(*EDIT_FIELDS)
        category = attributes[:category].presence || report.category
        attributes[:department] = ReportTaxonomy::CATEGORY_DEPARTMENT[category.to_s.to_sym] if values.has_key?(:category) || report.department.blank?
        recipient = attributes[:forwarding_recipient].presence || report.forwarding_recipient.presence || Sistem48::DepartmentRouting.email_for(category, report.organization)
        fail_with(:recipient) if recipient.present? && ReportCaseWorkflow.recipients(report.organization).exclude?(recipient)
        attributes.merge(forwarding_recipient: recipient)
      end

      def review
        edit_details
        fail_with(:category_required) if report.category.blank?
        return review_planned if report.planned? && report.collective?

        report.update!(reviewed_attributes.merge(review_state: "validated", needs_review: false,
                                                 response_due_at: due(report.forwarded_at ? ReportWorkQueue::CITY_DAYS : ReportWorkQueue::REVIEW_DAYS),
                                                 deadline_kind: report.forwarded_at ? "city" : "review"))
      end

      def review_planned
        collection = report.report_collection
        report.update!(reviewed_attributes.merge(review_state: "validated", needs_review: false, assigned_to: collection.assigned_to,
                                                 response_due_at: collection.review_due_at, deadline_kind: "planning"))
      end

      def ask
        edit_details
        report.update!(reviewed_attributes)
        question = workflow.message(body: required_text(:body), question: true, response_due_at: due(ReportWorkQueue::CITIZEN_DAYS).iso8601)
        # Confirmation question: silence by the deadline closes as resolved.
        ReportResolutionChecks.request!(report, question:, actor:) if values[:no_reply_outcome] == "resolve"
      end

      def send_to_service
        fail_with(:preview_required) if @approved_mail_digest.blank?
        review
        fail_with(:location_required) if @action == "send" && report.address.blank? && (report.latitude.nil? || report.longitude.nil?)
        kind = action == "send" ? "initial" : action
        ReportDispatching.queue!(report:, actor:, digest: ReportCaseWorkflow.digest(report), kind:, text: values[:body], approved_mail_digest: @approved_mail_digest)
      end

      def plan
        edit_details
        fail_with(:category_required) if report.category.blank?
        collection = if values[:report_collection_id].present?
                       ReportCollection.find_by!(organization: report.organization, id: values[:report_collection_id])
                     else
                       ReportCollection.create!(organization: report.organization, title: required_text(:collection_title, limit: 200),
                                                topic: required_text(:collection_topic, limit: 200), summary: required_text(:collection_summary),
                                                assigned_to: owner || actor, review_due_at: planning_due)
                     end
        ReportPlanning.new(report, actor).plan(report_collection_id: collection.id, report_subtype: values[:report_subtype],
                                               forwarding_note: values[:forwarding_note].presence || report.forwarding_note, confirm_review: "1")
        report.update!(reviewed_attributes.except(:assigned_to).merge(deadline_kind: "planning"))
      end

      def unplan
        ReportPlanning.new(report, actor).unplan
        report.update!(review_pending_since: Time.current, deadline_kind: "review", response_due_at: due(ReportWorkQueue::REVIEW_DAYS))
      end

      def settle
        reason = required_text(:reason, limit: 1000)
        case action
        when "reject"
          report.update!(reviewed_attributes.merge(status: "odbijeno", review_state: "rejected", status_note: reason, response_due_at: nil,
                                                   closure_basis: values[:closure_basis] == "bez_odgovora" ? "bez_odgovora" : report.closure_basis))
        when "resolve"
          evidence = required_text(:resolution_evidence)
          report.update!(reviewed_attributes.merge(status: "rijeseno", review_state: "validated", resolution_evidence: evidence, response_due_at: nil))
        when "reopen"
          report.update!(status: report.forwarded_at ? "u_obradi" : "primljeno", review_state: "pending", duplicate_of: nil,
                         review_pending_since: Time.current, response_due_at: due(ReportWorkQueue::REVIEW_DAYS), deadline_kind: "review")
        end
        # One status notification, no second conversation-message send. The
        # private reason is retained without copying it to generic audit rows.
        report.update!(internal_note: [report.internal_note.presence, "#{actor.name} · #{action}: #{reason}"].compact.join("\n\n"))
      end

      def duplicate
        target = Report.find_by(organization: report.organization, reference: required_text(:duplicate_reference, limit: 50))
        fail_with(:duplicate_invalid) unless target && target != report && !target.duplicate? && !report.duplicate_reports.exists?
        report.update!(reviewed_attributes.merge(duplicate_of: target, status: "odbijeno", review_state: "rejected", response_due_at: nil,
                                                 status_note: I18n.t("decidim.bih.review_workspace.duplicate_reason", reference: target.reference)))
        report.record_event!("duplicate_marked", actor:, metadata: { duplicate_of_reference: target.reference })
      end

      def external
        review
        workflow.record_external(reference: required_text(:external_reference, limit: 240))
        report.update!(deadline_kind: "city", response_due_at: due(ReportWorkQueue::CITY_DAYS))
      end

      def authorize!(permission)
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(actor, permission, organization: report.organization)
      end

      def validate_ai_proposal!
        return if values[:ai_proposal_id].blank?
        return unless AI_DECISION_ACTIONS.include?(action == "save_draft" ? values[:draft_action] : action)

        @ai_proposal = report.review_proposals.find_by(id: values[:ai_proposal_id])
        fail_with(:stale) unless @ai_proposal&.current?
      end

      def record_ai_decision
        return unless @ai_proposal && action != "save_draft"

        proposed = @ai_proposal.suggested_values.except("draft_action", "ai_proposal_id")
        changed = proposed.keys.reject do |key|
          actual = values.has_key?(key.to_sym) ? values[key.to_sym] : report.attributes[key]
          actual.to_s == proposed[key].to_s
        end
        changed << "action" if @ai_proposal.suggested_values["draft_action"] != action
        @ai_proposal.update!(decided_by: actor, decided_at: Time.current, approved_action: action, changed_fields: changed)
      end

      def audit!
        record_ai_decision
        metadata = { action:, review_state: report.review_state, status: report.status, display_status: ReportStatusPresenter.status_key(report),
                     reviewed_message_id: report.last_reviewed_message_id }
        metadata[:approval_key] = @approval_key if @approval_key
        metadata[:proposal_id] = @ai_proposal.id if @ai_proposal
        event = report.record_event!("case_decision_applied", actor:, metadata:)
        close_answered_staff_tasks!(event)
        OperatorAuditEvent.record!(organization: report.organization, actor:, event_type: "case_decision_applied", resource: report,
                                   permission: PERMISSIONS.fetch(action, :reports_update_status).to_s,
                                   metadata:)
      end

      # A substantive decision is the staff answer to the review and mail-review
      # tasks open before it; without this they kept the case in "Za pregled".
      # Approvals, delivery exceptions and closure approvals stay explicit.
      NON_ANSWERING_ACTIONS = %w(save_draft claim assign note).freeze

      def close_answered_staff_tasks!(event)
        return if event.nil? || NON_ANSWERING_ACTIONS.include?(action) || !ReportObligation.table_exists?

        report.obligations.open.where(actor: "staff", kind: %w(review mail_review)).where(created_at: ...event.occurred_at).find_each do |task|
          ReportObligations.fulfil!(task, by: event)
        end
      end

      def fail_with(key)
        raise Invalid, I18n.t("decidim.bih.review_workspace.errors.#{key}")
      end
    end
  end
end

# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

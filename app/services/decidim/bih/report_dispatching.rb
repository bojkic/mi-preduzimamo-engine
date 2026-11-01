# frozen_string_literal: true

require "digest"
require "securerandom"

module Decidim
  module Bih
    class ReportDispatching
      class Invalid < StandardError; end

      # Keep the approved mail digest explicit at this authorization boundary.
      def self.queue!(report:, actor:, digest:, kind: "initial", text: nil, approved_mail_digest: nil) # rubocop:disable Metrics/ParameterLists
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(actor, :reports_retry_forwarding, organization: report.organization)

        ReportMailbox::ReplyAddress.ensure!(report:, audience: "service", correspondents: recipients_for(report, kind))
        dispatch = nil
        report.with_lock do
          fail_with(:stale) unless digest == ReportCaseWorkflow.digest(report)
          fail_with(:not_ready) unless ready?(report, kind)
          fail_with(:in_flight) if report.dispatches.exists?(state: %w(queued sending unknown))
          mail = preview(report:, kind:, text:)
          fail_with(:stale) if approved_mail_digest.present? && approved_mail_digest != mail_digest(mail)
          previous_not_sent = report.dispatches.where(kind:, input_digest: digest, state: "not_sent").maximum(:id)
          identity = Digest::SHA256.hexdigest([report.id, kind, digest, text.to_s.strip, previous_not_sent].to_json)
          dispatch = report.dispatches.find_by(deduplication_key: identity)
          fail_with(:already_attempted) if dispatch
          dispatch = report.dispatches.create!(approved_by: actor, kind:, input_digest: digest, deduplication_key: identity,
                                               message_id: "#{SecureRandom.uuid}@#{report.organization.host}",
                                               snapshot: ReportEvidence.snapshot(mail))
          ReportEvidence.record_dispatch!(dispatch) if ReportEvidence.respond_to?(:record_dispatch!)
          report.record_event!("case_dispatch_queued", actor:, metadata: { dispatch_id: dispatch.id, kind: })
        end
        ActiveRecord.after_all_transactions_commit { enqueue(dispatch) }
        dispatch
      end

      def self.deliver!(dispatch)
        report = dispatch.report
        claimed = false
        report.with_lock do
          dispatch.reload
          next unless dispatch.state == "queued"

          unless ready?(report, dispatch.kind) && dispatch.input_digest == ReportCaseWorkflow.digest(report) &&
                 OperatorAuthorization.allowed?(dispatch.approved_by, :reports_retry_forwarding, organization: report.organization) &&
                 (Array(dispatch.snapshot.fetch("to")) - ReportCaseWorkflow.recipients(report.organization)).empty?
            dispatch.update!(state: "cancelled")
            report.record_event!("case_dispatch_cancelled", source: "background", metadata: { dispatch_id: dispatch.id })
            next
          end
          dispatch.update!(state: "sending", started_at: Time.current)
          claimed = true
        end
        ReportReviewAssistant.enqueue(report) unless claimed
        return unless claimed

        schedule_recovery(dispatch)

        # No DB transaction spans this irreversible operation. A crash leaves a
        # durable sending row; recovery marks it unknown, never queues it again.
        begin
          ReportDispatchMailer.delivery(dispatch.id).deliver_now
        rescue ReportMailbox::Transport::Unavailable
          dispatch.update!(state: "not_sent", error_class: "ReportMailbox::Transport::Unavailable")
          report.record_event!("case_dispatch_transport_unavailable", source: "background", metadata: { dispatch_id: dispatch.id,
                                                                                                        error_class: "ReportMailbox::Transport::Unavailable" })
          return
        rescue StandardError => e
          dispatch.update!(state: "unknown", error_class: e.class.name)
          report.record_event!("case_dispatch_unknown", source: "background", metadata: { dispatch_id: dispatch.id, error_class: e.class.name })
          return
        end
        accept!(dispatch)
      end

      def self.accept!(dispatch)
        dispatch.report.with_lock do
          dispatch.reload
          next if dispatch.state == "accepted"

          report = dispatch.report
          dispatch.update!(state: "accepted", accepted_at: Time.current)
          if dispatch.kind == "initial"
            attrs = { forwarded_at: dispatch.accepted_at }
            attrs[:status] = "proslijedjeno" unless Report::TERMINAL_STATUSES.include?(report.status)
            attrs.merge!(response_due_at: dispatch.accepted_at + ReportWorkQueue::CITY_DAYS.days, deadline_kind: "city") if report.review_state != "pending"
            report.update!(attrs)
          elsif report.review_state != "pending"
            report.update!(response_due_at: dispatch.accepted_at + ReportWorkQueue::CITY_DAYS.days, deadline_kind: "city")
          end
          ReportObligations.after_dispatch!(dispatch)
          report.clear_forwarding_failure!(reason: "forwarding_sent", source: "background") if report.forwarding_failed_at?
          report.record_event!("case_dispatch_accepted", source: "background", metadata: { dispatch_id: dispatch.id, kind: dispatch.kind })
        end
        ReportReviewAssistant.enqueue(dispatch.report.reload)
      end

      def self.reconcile!(dispatch:, actor:, accepted:, evidence:)
        report = dispatch.report
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(actor, :reports_retry_forwarding, organization: report.organization)

        fail_with(:evidence_required) if evidence.to_s.strip.blank? || evidence.to_s.length > 1000
        report.with_lock do
          dispatch.reload
          fail_with(:not_unknown) unless dispatch.state == "unknown"
          dispatch.update!(reconciled_by: actor, reconciled_at: Time.current, reconciliation_evidence: evidence.to_s.strip)
          accepted ? accept!(dispatch) : dispatch.update!(state: "not_sent")
          report.record_event!("case_dispatch_reconciled", actor:, metadata: { dispatch_id: dispatch.id, accepted: })
        end
        ReportReviewAssistant.enqueue(report.reload) unless accepted
      end

      def self.recover!(scope: ReportDispatch.all)
        scope.where(state: "sending", started_at: ...10.minutes.ago).find_each do |dispatch|
          dispatch.report.with_lock do
            dispatch.reload
            next unless dispatch.state == "sending" && dispatch.started_at < 10.minutes.ago

            dispatch.update!(state: "unknown", error_class: "InterruptedDelivery")
            dispatch.report.record_event!("case_dispatch_unknown", source: "background", metadata: { dispatch_id: dispatch.id })
          end
        end
        scope.where(state: "queued").find_each { |dispatch| enqueue(dispatch) }
      end

      def self.recipients_for(report, _kind = "initial")
        [report.forwarding_recipient.presence || Sistem48::DepartmentRouting.email_for(report.category, report.organization)]
      end

      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- approved transport snapshot and thread headers
      # The City receives the organization's language, whatever the staff UI uses.
      def self.preview(report:, kind: "initial", text: nil)
        I18n.with_locale(report.organization.default_locale.presence || I18n.default_locale) { build_preview(report:, kind:, text:) }
      end

      def self.build_preview(report:, kind:, text:)
        recipient = report.forwarding_recipient.presence || Sistem48::DepartmentRouting.email_for(report.category, report.organization)
        fail_with(:recipient) unless ReportCaseWorkflow.recipients(report.organization).include?(recipient)
        payload = report.to_forwarder_hash.merge(recipient:, photo_url: nil)
        if kind != "initial"
          fail_with(:text_required) if text.to_s.strip.blank? || text.to_s.length > 3000
          payload[:description] = text.to_s.strip
        end
        mail = Sistem48::ReportMailer.report_email(payload, evidence: []).message
        mail.from = Decidim::Bih.report_reply_mailbox if Decidim::Bih.report_mail_transport == "gmail"
        if kind != "initial"
          mail.subject = I18n.t("decidim.bih.review_workspace.dispatch_subjects.#{kind}", reference: report.reference)
          mail.body = "#{mail.subject}\n\n#{text.to_s.strip}\n"
        end
        reply_to = ReportMailbox::ReplyAddress.address_for(report:, audience: "service", correspondents: Array(mail.to))
        mail.reply_to = reply_to if reply_to
        if kind != "initial"
          chain = ReportMailbox::Conversation.message_ids(report:, correspondents: Array(mail.to))
          mail.in_reply_to = "<#{chain.last}>" if chain.any?
          mail.references = chain.map { |id| "<#{id}>" }.join(" ") if chain.any?
        end
        ReportEvidence.attach(mail, ReportEvidence.attachments(report, kind:))
        mail
      end

      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def self.mail_digest(mail)
        Digest::SHA256.hexdigest(ReportEvidence.snapshot(mail).to_json)
      end

      def self.schedule_recovery(dispatch)
        ReportDispatchRecoveryJob.set(wait: 11.minutes).perform_later(dispatch.id)
      rescue StandardError => e
        Rails.logger.error("[ReportDispatching] recovery enqueue pending id=#{dispatch.id} error=#{e.class}")
      end

      def self.ready?(report, kind)
        return false if report.duplicate? || Report::TERMINAL_STATUSES.include?(report.status) || report.review_state != "validated"
        return report.forwarded_at.nil? && !report.collective? && !report.planned? if kind == "initial"

        %w(supplement followup).include?(kind) && report.forwarded_at.present?
      end

      def self.enqueue(dispatch)
        ReportDispatchJob.perform_later(dispatch.id)
      rescue StandardError => e
        Rails.logger.error("[ReportDispatching] enqueue pending id=#{dispatch.id} error=#{e.class}")
      end

      def self.fail_with(key)
        raise Invalid, I18n.t("decidim.bih.review_workspace.errors.#{key}")
      end
    end
  end
end

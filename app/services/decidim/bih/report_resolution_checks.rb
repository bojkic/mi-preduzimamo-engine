# frozen_string_literal: true

module Decidim
  module Bih
    # Owner decision 2026-10-30: when the City reports the work as done or under
    # way, staff may ask the citizen to confirm it. Silence by the question
    # deadline closes the case as resolved (no second reminder, no rejection).
    # The citizen can still answer "problem persists" on the status page,
    # which reopens the case (ReportCaseWorkflow#reply).
    module ReportResolutionChecks
      EVENT = "case_resolution_check_requested"
      EVIDENCE = "Zamolili smo Vas da potvrdite da je problem otklonjen. Do isteka roka nismo dobili odgovor, pa prijavu zatvaramo kao riješenu. " \
                 "Ako problem i dalje postoji, javite nam to na stranici prijave i prijava će se ponovo otvoriti."

      module_function

      def request!(report, question:, actor:)
        report.record_event!(EVENT, actor:, metadata: { question_id: question.id })
      end

      def question(report)
        report.case_messages.where(actor_role: "staff", kind: "question").order(created_at: :desc, id: :desc).first
      end

      # Only the latest question counts: a later ordinary question ends the check.
      def requested?(report, latest = question(report))
        latest.present? && report.events.where(event_type: EVENT).exists?(["metadata ->> 'question_id' = ?", latest.id.to_s])
      end

      def candidates
        Report.where(review_state: "needs_information", duplicate_of_report_id: nil)
              .where.not(status: Report::TERMINAL_STATUSES)
              .where(id: ReportEvent.where(event_type: EVENT).select(:decidim_bih_report_id))
      end

      def due_reports(now: Time.current)
        candidates.where(response_due_at: ..now)
      end

      def close_due!(report)
        report.with_lock do
          latest = question(report)
          return :not_due unless report.review_state == "needs_information" && Report::TERMINAL_STATUSES.exclude?(report.status) &&
                                 report.response_due_at && report.response_due_at <= Time.current
          return :changed unless requested?(report, latest)
          return :replied if report.last_citizen_reply_at && report.last_citizen_reply_at >= latest.created_at
          return hold!(report, latest) if report.events.where(event_type: "citizen_channel_message").exists?(occurred_at: latest.created_at..)

          from_status = report.status
          report.update!(status: "rijeseno", review_state: "validated", resolution_evidence: EVIDENCE, response_due_at: nil, deadline_kind: nil)
          # status_changed also feeds the goodwill outcome correction.
          report.record_event!("status_changed", source: "system", metadata: { from_status:, to_status: "rijeseno",
                                                                               reason: "resolution_check_no_reply", question_id: latest.id })
          :closed
        end
      end

      # The citizen wrote over Viber/WhatsApp instead of the case page; that
      # message goes to the assistant, so staff decide instead of the clock.
      def hold!(report, latest)
        ReportObligations.open!(report, kind: "review", source: latest, effect_key: "resolution-check-hold:#{latest.id}",
                                        metadata: { reason: "citizen_replied_via_channel" })
        :held
      end
    end
  end
end

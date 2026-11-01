# frozen_string_literal: true

require "uri"

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- explicit case-state guards kept together

module Decidim
  module Bih
    # Owner decision 2026-10-05: every question left unanswered past its
    # deadline is repeated once over Viber or WhatsApp. A separate job rechecks
    # the case under its row lock before any provider request. Only a delivered
    # handset report starts the three-day window (provider acceptance does not);
    # an unanswered case then closes automatically. A later private reply
    # reopens it through reopen_after_reply!.
    module ReportSecondReminders
      REPLY_WINDOW_DAYS = 3
      CHANNELS = %w(viber whatsapp).freeze
      CLOSURE_REASON = "Nema odgovora nakon druge opomene za dopunu prijave. Istorija prijave je sačuvana."

      module_function

      def due_reports(now: Time.current)
        Report.where(review_state: "needs_information", duplicate_of_report_id: nil, response_due_at: ..now)
              .where.not(status: Report::TERMINAL_STATUSES).where.not(decidim_user_id: nil)
              .where.not(id: ReportSecondReminder.select(:report_id))
      end

      def prepare!(report)
        reminder = nil
        report.with_lock do
          raise ArgumentError, "already reminded" if report.second_reminder
          raise ArgumentError, "case no longer awaits a reply" unless waiting_for_reply?(report)
          raise ArgumentError, "confirmation question closes as resolved" if ReportResolutionChecks.requested?(report)

          question = report.case_messages.where(actor_role: "staff", kind: "question").order(created_at: :desc, id: :desc).first
          raise ArgumentError, "question missing" if question.nil? || question.body.blank?
          raise ArgumentError, "citizen replied" if report.last_citizen_reply_at && report.last_citizen_reply_at >= question.created_at

          user = report.author
          raise ArgumentError, "verified author required" unless user && user.decidim_organization_id == report.decidim_organization_id

          text = message_text(report, question)
          template = I18n.with_locale(user.locale.presence || report.organization.default_locale) do
            AccountNotifications.template_resolver&.call(topic: "report_updates", text:, reference: report.reference,
                                                         status: ReportStatusPresenter.label(report))
          end
          eligibility = AccountNotifications.preview(user:, organization: report.organization, topic: :report_updates,
                                                     text:, template:, channels: CHANNELS)
          channels = Array(eligibility[:channels]) & CHANNELS
          raise ArgumentError, "Viber/WhatsApp unavailable: #{eligibility[:reasons].to_h.values.compact.uniq.join(",")}" if channels.empty?

          notification = AccountNotifications.enqueue!(user:, organization: report.organization, topic: :report_updates,
                                                       text:, template:, channels:, expires_at: 24.hours.from_now,
                                                       deduplication_key: "report-second-reminder:#{report.id}:#{question.id}", enqueue_job: false)
          reminder = ReportSecondReminder.create!(report:, question:, account_notification: notification)
          # Provisional until delivery: the expired question deadline must not
          # ring "deadline passed" while the reminder is on its way.
          move_citizen_task!(report, Time.current + REPLY_WINDOW_DAYS.days)
          report.record_event!("case_second_reminder_prepared", source: "system", metadata: { question_id: question.id, notification_id: notification.id })
        end
        ReportSecondReminderJob.perform_later(reminder.id)
        reminder
      end

      def reconcile!(reminder)
        return reminder if reminder.closed_at || reminder.outcome == "replied"

        AccountNotifications.reconcile!(reminder.account_notification)
        reminder.report.with_lock do
          reminder.reload
          next if reminder.closed_at || reminder.outcome == "replied"

          report = reminder.report
          notification = reminder.account_notification.reload
          if report.last_citizen_reply_at && report.last_citizen_reply_at >= reminder.question.created_at
            reminder.update!(outcome: "replied")
          elsif notification.status == "delivered" && notification.channels.intersect?(CHANNELS) && notification.delivered_at
            next if reminder.outcome == "delivered"

            due = notification.delivered_at + REPLY_WINDOW_DAYS.days
            reminder.update!(outcome: "delivered", delivered_at: notification.delivered_at, response_due_at: due)
            report.update!(response_due_at: due, deadline_kind: "citizen") if waiting_for_reply?(report)
            move_citizen_task!(report, due)
          elsif %w(skipped rejected failed unknown).include?(notification.status)
            reminder.update!(outcome: notification.status == "skipped" ? "skipped" : "failed")
            hand_to_staff!(report, reminder)
          elsif notification.status == "accepted"
            reminder.update!(outcome: "accepted")
            # Still unconfirmed when the message expired: a managed Viber ->
            # WhatsApp chain can stay "accepted" after its primary failed.
            hand_to_staff!(report, reminder) if notification.expires_at&.past?
          end
        end
        reminder
      end

      def close_due!(reminder)
        report = reminder.report
        report.with_lock do
          reminder.reload
          return :not_due unless reminder.outcome == "delivered" && reminder.delivered_at &&
                                 reminder.response_due_at && reminder.response_due_at <= Time.current
          return :changed unless waiting_for_reply?(report) && report.response_due_at == reminder.response_due_at

          if report.last_citizen_reply_at && report.last_citizen_reply_at >= reminder.question.created_at
            reminder.update!(outcome: "replied")
            return :replied
          end
          return hold_for_channel_message!(report, reminder) if channel_message_since?(report, reminder)

          report.update!(status: "odbijeno", review_state: "rejected", status_note: CLOSURE_REASON, closure_basis: "bez_odgovora",
                         removed_from_public_at: Time.current, response_due_at: nil, deadline_kind: nil)
          reminder.update!(outcome: "closed", closed_at: Time.current)
          report.record_event!("case_second_reminder_closed", source: "system", metadata: { reminder_id: reminder.id })
          :closed
        end
      end

      # A Viber/WhatsApp message from the author goes to the chat assistant, not
      # into the case. Mark every case still waiting for that author's reply so
      # an automatic closure is held for staff instead of ignoring the answer.
      def note_channel_message!(user:, channel:)
        return 0 unless user

        reports = Report.where(organization: user.organization, decidim_user_id: user.id, review_state: "needs_information",
                               duplicate_of_report_id: nil).where.not(status: Report::TERMINAL_STATUSES)
        reports.find_each do |report|
          report.record_event!("citizen_channel_message", source: "system", actor_role: "citizen", metadata: { channel: channel.to_s })
        end
        reports.count
      end

      def move_citizen_task!(report, due)
        return unless defined?(ReportObligation) && ReportObligation.available?

        report.obligations.open.where(kind: "info_request", actor: "citizen").find_each do |task|
          task.update!(due_at: due, metadata: task.metadata.merge("second_reminder_due" => due.iso8601))
        end
      end

      def channel_message_since?(report, reminder)
        report.events.where(event_type: "citizen_channel_message").exists?(occurred_at: (reminder.delivered_at || reminder.created_at)..)
      end

      # Without a confirmed delivery the three-day window never starts, and an
      # expired citizen deadline alone does not reach "Za pregled". Open one
      # staff task so the case does not wait silently (BR-2026-0080/0085).
      def hand_to_staff!(report, reminder)
        return unless waiting_for_reply?(report)
        return if report.last_citizen_reply_at && report.last_citizen_reply_at >= reminder.question.created_at

        ReportObligations.open!(report, kind: "review", source: reminder.question, effect_key: "second-reminder-undelivered:#{reminder.id}",
                                        metadata: { reason: "second_reminder_undelivered", reminder_id: reminder.id })
      end

      def hold_for_channel_message!(report, reminder)
        ReportObligations.open!(report, kind: "review", source: reminder.question, effect_key: "second-reminder-hold:#{reminder.id}",
                                        metadata: { reason: "citizen_replied_via_channel", reminder_id: reminder.id })
        :held
      end

      # Caller holds the report lock and applies the usual reply review deadline.
      # Accept an existing reply as well, so an earlier missed reply can be repaired.
      def reopen_after_reply!(report, message:)
        return false unless citizen_reply_for_report?(report, message) && automatic_closure_state?(report)

        reminder = report.second_reminder&.reload
        return false unless reply_after_closure?(reminder, message) && automatic_closure_unchanged?(report, reminder)

        report.update!(status: "primljeno", review_state: "pending", removed_from_public_at: nil, status_note: nil)
        reminder.update!(outcome: "replied") # Retain closed_at and all delivery/deadline evidence.
        report.record_event!("status_changed", actor: message.actor, actor_role: "citizen", source: "public",
                                               metadata: { from_status: "odbijeno", to_status: "primljeno", reason: "late_reply_after_second_reminder",
                                                           reminder_id: reminder.id, message_id: message.id })
        true
      end

      def citizen_reply_for_report?(report, message)
        message.persisted? && message.report_id == report.id && message.actor_role == "citizen" && message.kind == "reply"
      end

      def automatic_closure_state?(report)
        report.status == "odbijeno" && report.review_state == "rejected" && !report.duplicate? &&
          report.removed_from_public_at && report.status_note == CLOSURE_REASON
      end

      def reply_after_closure?(reminder, message)
        reminder&.closed_at && %w(closed replied).include?(reminder.outcome) && message.created_at >= reminder.closed_at
      end

      def automatic_closure_unchanged?(report, reminder)
        return false if report.reviewed_at && report.reviewed_at >= reminder.closed_at

        closure = report.events.where(event_type: "case_second_reminder_closed", source: "system")
                        .where("metadata ->> 'reminder_id' = ?", reminder.id.to_s).order(id: :desc).first
        return false unless closure

        # IDs also distinguish a later staff decision made in the same timestamp.
        !report.events.where("id > ?", closure.id)
               .where("event_type <> 'case_decision_applied' OR COALESCE(metadata ->> 'action', '') NOT IN (?)", %w(save_draft claim assign note))
               .exists?(event_type: %w(case_reviewed case_decision_applied status_changed duplicate_marked duplicate_cleared))
      end

      def waiting_for_reply?(report)
        report.review_state == "needs_information" && Report::TERMINAL_STATUSES.exclude?(report.status) &&
          report.response_due_at && report.response_due_at <= Time.current
      end

      def message_text(report, question)
        url = URI.join("https://#{report.organization.host}", report.tokenized_status_path).to_s
        "Podsjećamo Vas da za prijavu #{report.reference} trebamo dopunu: #{question.body.strip}. " \
          "Molimo Vas da dostavite tražene informacije u roku od 3 dana od dostave ove poruke putem #{url}. " \
          "Ako ne odgovorite u tom roku, prijava će biti zatvorena. " \
          "Istorija prijave ostaje sačuvana i kasnijim odgovorom na istom linku prijava se ponovo otvara."
      end
    end
  end
end

# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

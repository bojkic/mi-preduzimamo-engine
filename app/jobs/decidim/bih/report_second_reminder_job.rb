# frozen_string_literal: true

module Decidim
  module Bih
    class ReportSecondReminderJob < ApplicationJob
      self.log_arguments = false
      queue_as :integrations

      def perform(reminder_id)
        reminder = ReportSecondReminder.find_by(id: reminder_id)
        return unless reminder

        claimed = reminder.report.with_lock do
          reminder.reload
          next false unless reminder.outcome == "pending" && reminder.account_notification.status == "pending"

          # This claim commits before the provider request. A crash after this
          # point leaves an operator-visible uncertainty, never a second send.
          reminder.update!(outcome: "claimed")
          true
        end
        return unless claimed

        reminder.report.with_lock do
          reminder.reload
          report = reminder.report
          notification = reminder.account_notification
          next unless reminder.outcome == "claimed"

          if !ReportSecondReminders.waiting_for_reply?(report) ||
             (report.last_citizen_reply_at && report.last_citizen_reply_at >= reminder.question.created_at)
            notification.update!(status: "skipped", reason: "case_changed") if notification.status == "pending"
            reminder.update!(outcome: "skipped") if notification.status == "skipped"
            next
          end

          # Hold the report lock across the send so a concurrent citizen reply
          # cannot commit between the final case check and the request. The
          # reminder claim above prevents a retry from repeating this request.
          AccountNotifications.dispatch!(notification) if notification.status == "pending"
          outcome = { "accepted" => "accepted", "delivered" => "delivered", "skipped" => "skipped",
                      "rejected" => "failed", "failed" => "failed", "unknown" => "failed" }[notification.reload.status]
          reminder.update!(outcome:) if outcome
          ReportSecondReminders.hand_to_staff!(report, reminder) if outcome == "failed"
        end
      end
    end
  end
end

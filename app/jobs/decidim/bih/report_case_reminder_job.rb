# frozen_string_literal: true

module Decidim
  module Bih
    class ReportCaseReminderJob < ApplicationJob
      queue_as :reports

      def perform
        ReportPhotoDraft.cleanup!
        ReportDispatching.recover!
        # Daily backstop for the five-minute sweep in ReportMailboxRecoveryJob.
        ReportReviewProposalRecovery.run!
        ReportResolutionChecks.due_reports.find_each do |report|
          ReportResolutionChecks.close_due!(report)
        rescue StandardError => e
          Rails.logger.warn("[ReportCaseReminderJob] resolution check report=#{report.id} error=#{e.class}")
        end
        ReportSecondReminders.due_reports.find_each do |report|
          ReportSecondReminders.prepare!(report)
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          Rails.logger.info("[ReportCaseReminderJob] second reminder report=#{report.id} not_sent=#{e.message.to_s.first(80)}")
        end
        ReportSecondReminder.where(outcome: %w(pending accepted delivered)).find_each do |second_reminder|
          ReportSecondReminders.reconcile!(second_reminder)
          ReportSecondReminders.close_due!(second_reminder)
        rescue StandardError => e
          Rails.logger.warn("[ReportCaseReminderJob] second reminder id=#{second_reminder.id} error=#{e.class}")
        end
        begin
          ReportCityFollowups.run!
        rescue StandardError => e
          Rails.logger.warn("[ReportCaseReminderJob] city followups error=#{e.class}")
        end
        overdue = Hash.new { |hash, user| hash[user] = [] }
        ReportWorkQueue.overdue.find_each do |report|
          remind(report).each { |user| overdue[user] << report.reference }
        end
        alert_phones(overdue)
        # Recover notification enqueue gaps without repeating committed bells.
        ReportMessage.where(notified_at: nil).find_each { |message| ReportCaseMessageJob.perform_later(message.id) }
        Report.where.not(status: Report::TERMINAL_STATUSES)
              .where.not(id: ReportEvent.where(event_type: "staff_alerts_created").select(:decidim_bih_report_id))
              .find_each { |report| ReportStaffAlertJob.perform_later(report.id) }
      end

      private

      # Returns the staff users whose bell rang for this newly passed deadline.
      def remind(report)
        notifications = []
        report.with_lock do
          deadline = ReportWorkQueue.due_at(report)
          next if deadline.nil? || deadline >= Time.current || report.reminded_due_at == deadline

          staff = ReportCaseWorkflow.staff(report.organization)
          assigned = staff.find_by(id: report.assigned_to_id)
          staff = staff.where(admin: true).or(staff.where(id: assigned.id)) if assigned
          staff.find_each do |user|
            notifications << Decidim::Notification.create!(user:, resource: user,
                                                           event_name: "decidim.events.bih.report_overdue", event_class: "Decidim::Bih::ReportCaseReminderEvent",
                                                           extra: { reference: report.reference, received_as: "affected_user" })
          end
          report.update!(reminded_due_at: deadline)
          report.record_event!("case_deadline_reminded", source: "background", metadata: { recipient_count: notifications.size })
        end
        notifications.each { |notification| Decidim::SendPushNotification.new.perform(notification) }
        notifications.map(&:user)
      end

      # Owner decision 2026-10-30: the bell alone went unseen (BR-2026-0029 and
      # BR-2026-0038 sat overdue for days). Each staff member also gets one
      # Viber summary per run of the cases whose deadline has just passed.
      def alert_phones(overdue)
        overdue.each do |user, references|
          more = references.size > 10 ? " i još #{references.size - 10}" : ""
          text = "MI platforma: istekao je rok za #{references.size == 1 ? "prijavu" : "prijave"} " \
                 "#{references.first(10).join(", ")}#{more}. Pregled: https://#{user.organization.host}/admin/bih/reports"
          AccountNotifications.enqueue!(user:, organization: user.organization, topic: "report_updates", text:, channels: %w(viber),
                                        expires_at: 12.hours.from_now,
                                        deduplication_key: "report-overdue:#{user.id}:#{Digest::SHA256.hexdigest(references.sort.join(","))}")
        rescue StandardError => e
          Rails.logger.warn("[ReportCaseReminderJob] overdue phone alert not sent user=#{user.id}: #{e.class}")
        end
      end
    end
  end
end

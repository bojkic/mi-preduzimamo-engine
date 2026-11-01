# frozen_string_literal: true

module Decidim
  module Bih
    # One committed bell batch per report, including durable chat intake replays.
    # No report content or citizen identity is copied into staff notifications.
    class ReportStaffAlertJob < ApplicationJob
      queue_as :reports

      EVENT_NAME = "decidim.events.bih.report_received"
      MESSAGE_CLASS = "report.staff_alert"
      BELL_GROUP = "bell"
      BELL_REASON = "bell_created"

      def perform(report_id)
        report = Report.find_by(id: report_id)
        return unless report

        notifications = []
        report.with_lock do
          return if report.events.exists?(event_type: "staff_alerts_created")

          recipients(report).find_each do |user|
            notifications << Decidim::Notification.create!(
              user: user, resource: user, event_name: EVENT_NAME,
              event_class: "Decidim::Bih::ReportReceivedEvent",
              extra: { reference: report.reference, received_as: "affected_user" }
            )
          end
          report.record_event!("staff_alerts_created", source: "background", actor_role: "system",
                                                       metadata: { recipient_count: notifications.size })
        end
        record_bells(report, notifications)
        notifications.each { |notification| push(notification) }
      end

      private

      # One attempt per staff bell. The batch is one logical message per
      # recipient, not one row for the batch: a staff member whose bell was
      # never created and one whose bell exists are different facts, and a
      # single batch row cannot tell them apart.
      #
      # Recorded after the lock commits and never allowed to raise — a ledger
      # that will not write must not cost an operator their case alert.
      def record_bells(report, notifications)
        organization = report.organization
        notifications.each do |notification|
          Decidim::Bih::Messaging::Correlation.observe!(
            organization:, message_class: MESSAGE_CLASS,
            recipient: Decidim::Bih::Messaging::RecipientContext.staff(
              organization_id: organization.id, account_id: notification.decidim_user_id,
              audience_role: "reports_read"
            ),
            correlation_key: "report:#{report.id}:staff_alert:#{notification.decidim_user_id}",
            deduplication_scope: "#{MESSAGE_CLASS}:#{BELL_GROUP}",
            group: BELL_GROUP, channel: "bell",
            outcome: Decidim::Bih::Messaging::Outcome::ACCEPTED, reason: BELL_REASON,
            leg_ref: notification.id,
            destination: { kind: :account }
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[messaging] staff alert bell correlation: #{e.class}")
      end

      def recipients(report)
        operators = OperatorRole.active.where(organization: report.organization)
                                .for_permission(:reports_read).select(:decidim_user_id)
        users = Decidim::User.where(organization: report.organization, deleted_at: nil, blocked: false)
        users.where(admin: true).or(users.where(id: operators))
      end

      # Push is a best-effort nudge; the committed bell alert remains available.
      def push(notification)
        Decidim::SendPushNotification.new.perform(notification)
      rescue StandardError => e
        Rails.logger.error("[ReportStaffAlertJob] push enqueue failed notification=#{notification.id} error=#{e.class}")
      end
    end
  end
end

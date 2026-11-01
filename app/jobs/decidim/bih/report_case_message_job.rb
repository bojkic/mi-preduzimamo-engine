# frozen_string_literal: true

module Decidim
  module Bih
    class ReportCaseMessageJob < ApplicationJob
      queue_as :reports

      # The direct bell and the account external copy are two different things
      # with two different permission contracts, and they get two different
      # registry keys. A citizen's message alerts STAFF; a staff message alerts
      # the report's AUTHOR. Neither is the external copy, which
      # `AccountNotifications` owns.
      BELL_CLASS = { "citizen" => "report.case_message_to_staff",
                     "staff" => "report.case_message_to_author" }.freeze
      BELL_GROUP = "bell"
      BELL_REASON = "bell_created"

      def perform(message_id)
        message = ReportMessage.find_by(id: message_id)
        return unless message

        notifications = []
        intent = nil
        message.with_lock do
          intent = message.account_notification
          next if message.notified_at?

          intent ||= external_notification(message)

          report = message.report
          recipients = if message.actor_role == "citizen"
                         ReportCaseWorkflow.staff(report.organization)
                       else
                         Decidim::User.where(id: report.decidim_user_id, organization: report.organization, blocked: false, deleted_at: nil)
                       end
          recipients.find_each do |user|
            notifications << Decidim::Notification.create!(user:, resource: user,
                                                           event_name: "decidim.events.bih.report_case_message", event_class: "Decidim::Bih::ReportCaseMessageEvent",
                                                           extra: { report_id: report.id, reference: report.reference, received_as: "affected_user",
                                                                    proactive_channel: intent && !ReportPushFollowup.scheduled_at(intent) ? "external" : "push" })
          end
          message.update!(notified_at: Time.current, notification_state: notifications.any? ? "bell_created" : "no_recipient")
        end
        record_bells(message, notifications)
        AccountNotifications.enqueue_pending(intent) if intent
        notifications.each { |notification| Decidim::SendPushNotification.new.perform(notification) }
      end

      private

      # A bell row is a real delivery leg and gets one attempt. What it is NOT
      # is handset delivery: the citizen has an inbox row, and whether they ever
      # open it is not observable here — `decidim_notifications` has no read_at
      # at all. So the outcome is `accepted` with the reason `bell_created`, and
      # nothing in this file may ever write `delivered`.
      #
      # Correlation is observational: it runs AFTER the lock has committed the
      # bells, and a ledger failure leaves the citizen with their notification.
      def record_bells(message, notifications)
        message_class = BELL_CLASS[message.actor_role.to_s]
        return if message_class.nil? || notifications.empty?

        organization = message.report.organization
        notifications.each do |notification|
          Messaging::Correlation.observe!(
            organization:, message_class:, recipient: bell_recipient(message, notification, organization),
            correlation_key: "report_message:#{message.id}:bell:#{notification.decidim_user_id}",
            deduplication_scope: "#{message_class}:#{BELL_GROUP}",
            group: BELL_GROUP, channel: "bell", outcome: Messaging::Outcome::ACCEPTED,
            reason: BELL_REASON, leg_ref: notification.id,
            # A bell has no transport destination. Recording the KIND and no
            # digest is the honest shape; hashing "user:<id>" would mint a
            # stable per-person pointer that buys nothing.
            destination: { kind: :account }
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[messaging] report case bell correlation: #{e.class}")
      end

      def bell_recipient(message, notification, organization)
        account_id = notification.decidim_user_id
        if message.actor_role.to_s == "staff"
          Messaging::RecipientContext.account(organization_id: organization.id, account_id:)
        else
          Messaging::RecipientContext.staff(organization_id: organization.id, account_id:,
                                            audience_role: "report_case_staff")
        end
      end

      def active_author?(user, report)
        user && user.organization == report.organization && !user.blocked? && !user.deleted?
      end

      def external_notification(message)
        return message.account_notification if message.account_notification
        return unless message.actor_role == "staff"

        report = message.report
        user = report.author
        return unless active_author?(user, report)
        push_first = WebPush.available_for?(user, topic: :report_updates)

        I18n.with_locale(user.locale.presence || report.organization.default_locale) do
          status = ReportStatusPresenter.label(report)
          text = message.external_notification_text
          template = AccountNotifications.template_resolver&.call(topic: "report_updates", text: text, reference: report.reference, status: status)
          intent = AccountNotifications.enqueue!(user: user, organization: report.organization, topic: "report_updates", text: text,
                                                 template: template, deduplication_key: "report-case-message:#{message.id}",
                                                 message_class: "report.case_message_to_author", enqueue_job: false,
                                                 channels: push_first ? %w(viber whatsapp) : AccountNotifications::CHANNELS,
                                                 context: push_first ? ReportPushFollowup.context(message) : {},
                                                 expires_at: push_first ? 48.hours.from_now : 24.hours.from_now)
          message.update!(account_notification: intent)
          intent
        end
      end
    end
  end
end

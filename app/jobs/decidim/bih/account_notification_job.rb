# frozen_string_literal: true

module Decidim
  module Bih
    class AccountNotificationJob < Decidim::ApplicationJob
      self.log_arguments = false
      queue_as :integrations

      def perform(notification_id)
        notification = AccountNotification.find_by(id: notification_id)
        return unless notification

        # The generic pending-intent recovery sweep also queues this job. Keep
        # a second reminder behind its report lock on every dispatch path.
        if (reminder = ReportSecondReminder.find_by(account_notification_id: notification.id))
          ReportSecondReminderJob.perform_now(reminder.id)
        else
          AccountNotifications.dispatch!(notification)
        end
      end
    end
  end
end

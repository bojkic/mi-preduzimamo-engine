# frozen_string_literal: true

module Decidim
  module Bih
    module Infobip
      # Compatibility consumer for old queue entries. Raw destinations cannot
      # establish current account ownership or permission and are discarded.
      # New producers use AccountNotifications and queue only its durable ID.
      class SendViberBusinessTextJob < Decidim::ApplicationJob
        self.log_arguments = false
        queue_as :integrations

        def perform(notification_id: nil, **_legacy_arguments)
          if notification_id
            AccountNotificationJob.perform_now(notification_id)
          else
            Rails.logger.info("[SendViberBusinessTextJob] skipped legacy unscoped notification")
          end
        end
      end
    end
  end
end

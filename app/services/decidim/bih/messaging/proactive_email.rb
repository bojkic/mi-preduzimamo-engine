# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # One account-email gate, also called when a queued mail is rendered.
      # Report contacts without an account remain scoped to their own report.
      module ProactiveEmail
        module_function

        def allowed?(user, topic:)
          return false unless user && !user.deleted? && !user.blocked?
          return false unless TopicPreferences.enabled?(user, topic:)
          return false unless EmailConfirmation.confirmed?(user) && user.email.present?

          digest = SuppressionKey.digest(kind: "email", value: user.email)
          !Suppression.blocking_for(organization: user.organization, provider: "smtp", channel: "email", destination_digest: digest)
        end

        def report_allowed?(report)
          return false if report.reporter_email.blank?

          author = report.author
          if author && author.decidim_organization_id == report.decidim_organization_id
            return false unless TopicPreferences.enabled?(author, topic: :report_updates)
            return false if author.deleted? || author.blocked?
          end
          digest = SuppressionKey.digest(kind: "email", value: report.reporter_email)
          !Suppression.blocking_for(organization: report.organization, provider: "smtp", channel: "email", destination_digest: digest)
        end

        def event_allowed?(user, event:, extra: {}, push_event: false)
          extra = extra.to_h.stringify_keys
          return false if extra["proactive_delivery"] == false
          return false if extra["proactive_channel"].present? && extra["proactive_channel"] != "email"

          topic = NotificationTopic.for_event(event, extra:)
          return false unless allowed?(user, topic:)
          return false if push_event && WebPush.available_for?(user, topic:)

          true
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # The existing durable account intent owns one phone reminder. Its encrypted
    # context carries the delay, so queue recovery cannot accidentally send early.
    class ReportPushFollowup
      CONTEXT_KEY = "report_push_followup_message_id"

      def self.context(message)
        { CONTEXT_KEY => message.id, "not_before" => 24.hours.from_now.iso8601(6) }
      end

      def self.scheduled_at(notification)
        payload = notification.payload
        return unless payload.fetch("context", {}).key?(CONTEXT_KEY)

        Time.iso8601(payload.fetch("context").fetch("not_before"))
      end

      def self.due?(notification)
        due_at = scheduled_at(notification)
        due_at.nil? || due_at <= Time.current
      rescue StandardError
        # Let dispatch mark unreadable or invalid intents skipped, never strand
        # them in recovery or fall back to an immediate send.
        true
      end

      # Run after the durable sending claim commits, immediately around transport.
      # Report replies lock the report; opening the case updates message rows.
      # Holding both locks serializes these actions with the provider request.
      def self.call(notification:, payload:)
        context = payload.fetch("context", {})
        return yield unless context.key?(CONTEXT_KEY)

        begin
          due_at = Time.iso8601(context.fetch("not_before"))
        rescue ArgumentError, KeyError
          notification.update!(status: "skipped", reason: "report_followup_invalid")
          return
        end
        message = ReportMessage.find_by(id: context[CONTEXT_KEY])
        unless message && due_at <= Time.current
          notification.update!(status: "skipped", reason: "report_followup_unavailable")
          return
        end

        message.report.with_lock do
          message.with_lock do
            report = message.report
            answered = report.case_messages.where(actor_role: "citizen").where("created_at >= ?", message.created_at).exists?
            superseded = report.case_messages.where(actor_role: "staff").where("id > ?", message.id).exists?
            current = message.actor_role == "staff" && message.read_at.nil? && !answered && !superseded &&
                      message.account_notification_id == notification.id && report.decidim_user_id == notification.decidim_user_id &&
                      report.decidim_organization_id == notification.decidim_organization_id
            unless current
              notification.update!(status: "skipped", reason: "report_message_opened_answered_or_replaced")
              next
            end
            yield
          end
        end
      end
    end
  end
end

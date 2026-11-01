# frozen_string_literal: true

module Decidim
  module Bih
    # Sends operator messages and writes audit rows without exposing
    # contact identifiers to the operator.
    class OperatorMessenger
      def self.call(**attributes)
        new(**attributes).call
      end

      def initialize(**attributes)
        @organization = attributes.fetch(:organization)
        @sender = attributes.fetch(:sender)
        @recipient = attributes.fetch(:recipient)
        @subject = attributes.fetch(:subject)
        @body = attributes.fetch(:body)
        @context = attributes[:context]
        @external_notification = attributes[:external_notification]
        @permission = attributes.fetch(:permission, "operator_message_send").to_s
      end

      def call
        message = nil
        fresh = false
        intent = nil
        case_message = nil
        OperatorMessage.transaction do
          message = persist_message
          fresh = message.previously_new_record?
          if external_copy_required?
            intent = AccountNotifications.enqueue!(user: recipient, organization: organization,
                                                   **@external_notification, enqueue_job: false)
          end
          record_audit(message) if fresh
          case_message = fresh_case_message(intent, fresh)
        end
        # The durable intent remains recoverable if this process exits here or
        # Redis is unavailable. A repeated preview resolves the same intent.
        enqueue_intent(intent) if intent
        @proactive_channel = intent ? "external" : "push"
        publish(message) if fresh && case_message.nil?
        enqueue_case_message(case_message) if case_message
        message
      end

      private

      attr_reader :organization, :sender, :recipient, :subject, :body, :context, :permission

      def fresh_case_message(intent, fresh)
        record_case_message(intent) if fresh && context.is_a?(Report)
      end

      def external_copy_required?
        @external_notification && !WebPush.available_for?(recipient, topic: @external_notification.fetch(:topic))
      end

      def record_case_message(intent)
        result = context.case_messages.create!(actor: sender, actor_role: "staff", kind: "update",
                                               body: [subject, body].join("\n\n"), account_notification: intent)
        context.record_event!("case_message_created", actor: sender, metadata: { message_id: result.id, kind: "update" })
        result
      end

      def enqueue_case_message(message)
        ReportCaseMessageJob.perform_later(message.id)
      rescue StandardError => e
        Rails.logger.error("[OperatorMessenger] case notification awaiting recovery id=#{message.id} error=#{e.class}")
      end

      def persist_message
        attributes = {
          organization: organization, sender: sender, recipient: recipient,
          subject: subject, body: body, context_type: context ? context.class.base_class.name : nil,
          context_id: context&.id, sent_at: Time.current
        }
        return OperatorMessage.create!(attributes) unless @external_notification

        digest = Digest::SHA256.hexdigest(@external_notification.fetch(:deduplication_key))
        OperatorMessage.create_or_find_by!(organization: organization, delivery_request_digest: digest) do |record|
          record.assign_attributes(attributes)
        end
      end

      def record_audit(message)
        OperatorAuditEvent.record!(
          organization: organization, actor: sender, event_type: "operator_message_sent", permission: permission,
          role: OperatorAuthorization.role_for(sender, permission, organization: organization), resource: message,
          metadata: {
            recipient_id: recipient.id, context_type: message.context_type, context_id: message.context_id,
            subject_length: message.subject.length, body_length: message.body.length,
            external_copy_requested: @external_notification.present?, notification_topic: @external_notification&.fetch(:topic, nil)
          }.compact
        )
      end

      def enqueue_intent(intent)
        AccountNotificationJob.perform_later(intent.id) if intent.status == "pending"
      rescue StandardError => e
        Rails.logger.error("[OperatorMessenger] durable intent awaiting queue recovery id=#{intent.id} error=#{e.class}")
      end

      def publish(message)
        Decidim::EventsManager.publish(
          event: "decidim.events.bih.operator.message",
          event_class: Decidim::Bih::OperatorMessageEvent,
          resource: recipient,
          affected_users: [recipient],
          force_send: true,
          extra: {
            subject: message.subject,
            body: message.body,
            proactive_channel: @proactive_channel,
            notification_topic: message.context_type == "Decidim::Bih::Report" ? "report_updates" : "community_news"
          }
        )
      rescue StandardError => e
        Rails.logger.error(
          "[OperatorMessenger] notification failed for message #{message.id}: #{e.class}: #{e.message}"
        )
        nil
      end
    end
  end
end

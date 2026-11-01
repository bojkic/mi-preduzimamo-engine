# frozen_string_literal: true

module Decidim
  module Bih
    # Sends one in-app and one email warning at the 30- and 7-day thresholds.
    # OperatorAuditEvent is the durable, PII-minimized deduplication record.
    class OperatorRoleExpiryNotifier
      WARNING_DAYS = [30, 7].freeze

      def self.call(now: Time.current)
        new(now:).call
      end

      def initialize(now: Time.current)
        @now = now
      end

      def call
        OperatorRole.active.includes(:user, :organization).find_each.sum do |role|
          warning_days = threshold_for(role)
          next 0 unless warning_days && !sent?(role, warning_days)

          publish(role, warning_days)
          record(role, warning_days)
          1
        end
      end

      private

      attr_reader :now

      def threshold_for(role)
        remaining = role.expires_at - now
        return if remaining.negative? || remaining > 30.days

        remaining <= 7.days ? 7 : 30
      end

      def sent?(role, warning_days)
        OperatorAuditEvent.where(
          organization: role.organization,
          event_type: "operator_role_expiry_warning_sent",
          resource_type: role.class.base_class.name,
          resource_id: role.id
        ).exists?(["metadata ->> 'warning_days' = ?", warning_days.to_s])
      end

      def publish(role, warning_days)
        extra = { role: role.role, expires_on: role.expires_at.to_date.iso8601, warning_days: }
        Decidim::EventsManager.publish(
          event: "decidim.events.bih.operator_role.expiry",
          event_class: Decidim::Bih::OperatorRoleExpiryEvent,
          resource: role.user,
          affected_users: [role.user],
          force_send: true,
          extra:
        )
        OperatorRoleExpiryMailer.warning(role, warning_days:).deliver_later if role.user.email.present?
      end

      def record(role, warning_days)
        OperatorAuditEvent.record!(
          organization: role.organization,
          actor: nil,
          event_type: "operator_role_expiry_warning_sent",
          permission: "operator_roles_manage",
          role: role.role,
          resource: role,
          metadata: { warning_days:, expires_on: role.expires_at.to_date.iso8601, user_id: role.user.id }
        )
      end
    end
  end
end

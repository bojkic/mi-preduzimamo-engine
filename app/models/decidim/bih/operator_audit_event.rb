# frozen_string_literal: true

module Decidim
  module Bih
    # Append-only, PII-minimized audit row for BIH operator actions.
    class OperatorAuditEvent < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_operator_audit_events"

      FORBIDDEN_METADATA_KEYS = %w(
        address body contact description email internal_note message note params payload phone
        provider_payload raw recipient_list report_description request_ip session_digest
        status_token user_agent viber_id viber_sender
      ).freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id",
                 optional: true

      before_validation :set_defaults
      before_validation :sanitize_metadata

      validates :event_type, presence: true
      validates :occurred_at, presence: true

      scope :recent, -> { order(occurred_at: :desc, id: :desc) }

      def readonly?
        persisted?
      end

      def self.record!(**attributes)
        organization = attributes.fetch(:organization)
        actor = attributes.fetch(:actor)
        event_type = attributes.fetch(:event_type)
        permission = attributes[:permission]
        role = attributes[:role]
        resource = attributes[:resource]
        metadata = attributes.fetch(:metadata, {})
        resource_type = resource ? resource.class.base_class.name : nil
        create!(
          organization:,
          user: actor,
          event_type: event_type.to_s,
          permission: permission.to_s.presence,
          role: role.to_s.presence,
          resource_type:,
          resource_id: resource&.id,
          metadata:
        )
      end

      private

      def set_defaults
        self.occurred_at ||= Time.current
        self.metadata ||= {}
      end

      def sanitize_metadata
        self.metadata = sanitized_hash(metadata || {})
      end

      def sanitized_hash(hash)
        hash.to_h.each_with_object({}) do |(key, value), sanitized|
          key = key.to_s
          next if FORBIDDEN_METADATA_KEYS.include?(key)

          sanitized[key] = sanitized_value(value)
        end
      end

      def sanitized_value(value)
        case value
        when Hash
          sanitized_hash(value)
        when Array
          value.map { |entry| sanitized_value(entry) }
        else
          value
        end
      end
    end
  end
end

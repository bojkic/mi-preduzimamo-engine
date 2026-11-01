# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Append-only operator audit trail for reward fulfillment handovers.
      # Metadata must remain PII-minimized: states, reward keys, point costs,
      # ledger ids and batch counts are fine; citizen contact data, free-text
      # pickup notes, provider payloads and notification bodies are not.
      class RewardFulfillmentEvent < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_reward_fulfillment_events"

        EVENT_TYPES = %w(requested reserved fulfilled canceled reversed).freeze
        SOURCES = %w(admin public background system).freeze
        FORBIDDEN_METADATA_KEYS = %w(
          address
          contact
          email
          fulfillment_note
          message
          note
          params
          payload
          phone
          pickup_location
          provider_payload
          recipient
          request_ip
          user_agent
          viber_id
        ).freeze

        belongs_to :fulfillment,
                   class_name: "Decidim::Bih::Goodwill::RewardFulfillment",
                   foreign_key: "decidim_bih_goodwill_reward_fulfillment_id",
                   inverse_of: :events
        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"
        belongs_to :actor,
                   class_name: "Decidim::User",
                   foreign_key: "decidim_user_id",
                   optional: true

        validates :event_type, inclusion: { in: EVENT_TYPES }
        validates :source, inclusion: { in: SOURCES }
        validates :occurred_at, presence: true
        validate :same_organization_as_fulfillment
        validate :actor_same_organization

        before_validation :set_defaults
        before_validation :copy_organization_from_fulfillment
        before_update :prevent_mutation
        before_destroy :prevent_mutation

        scope :chronological, -> { order(:occurred_at, :id) }
        scope :recent, -> { order(occurred_at: :desc, id: :desc) }

        def self.available?
          connection.data_source_exists?(table_name)
        rescue StandardError
          false
        end

        def self.sanitize_metadata(metadata)
          metadata.to_h.each_with_object({}) do |(key, value), sanitized|
            key = key.to_s
            next if key.blank? || value.nil? || FORBIDDEN_METADATA_KEYS.include?(key)

            sanitized[key] = sanitize_metadata_value(value)
          end
        end

        def self.sanitize_metadata_value(value)
          case value
          when Hash
            sanitize_metadata(value)
          when Array
            value.map { |item| sanitize_metadata_value(item) }
          when Time, Date, ActiveSupport::TimeWithZone
            value.iso8601
          when TrueClass, FalseClass, Numeric
            value
          else
            value.to_s
          end
        end

        def actor_label
          return I18n.t("decidim.bih.admin.goodwill.events.system_actor", default: "System") unless actor

          actor.name.presence ||
            actor.nickname.presence ||
            I18n.t("decidim.bih.admin.goodwill.events.admin_actor", id: actor.id, default: "Admin #%{id}")
        end

        private

        def set_defaults
          self.occurred_at ||= Time.current
          self.source ||= actor ? "admin" : "system"
          self.actor_role ||= actor ? "admin" : source
        end

        def copy_organization_from_fulfillment
          self.organization ||= fulfillment&.organization
        end

        def same_organization_as_fulfillment
          return unless fulfillment && organization
          return if fulfillment.decidim_organization_id == organization.id

          errors.add(:decidim_organization_id, :invalid)
        end

        def actor_same_organization
          return unless actor && organization
          return if actor.decidim_organization_id == organization.id

          errors.add(:decidim_user_id, :invalid)
        end

        def prevent_mutation
          raise ActiveRecord::ReadOnlyRecord, "reward fulfillment events are append-only"
        end
      end
    end
  end
end

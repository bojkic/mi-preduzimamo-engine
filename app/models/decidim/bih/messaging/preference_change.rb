# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # How a preference came to be what it is. Append-only.
      #
      # It records the previous and new state, the ACTUAL actor class (a
      # citizen, an operator, the organization's policy, a provider webhook, an
      # import), the operation and the policy/UI revision in force. A previous
      # state of nil means "there was no stored value" and must stay nil — the
      # cheap lie would be to write `blocked` there and invent a refusal.
      #
      # There is deliberately no column for message content, a code or a private
      # body: this is a consent trail, not a copy of what was sent.
      class PreferenceChange < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_messaging_preference_changes"

        ACTOR_TYPES = %w(citizen operator organization_policy provider system_import).freeze
        OPERATIONS = %w(set mirror import organization_default provider_opt_out reactivation).freeze
        SOURCES = Preference::SOURCES
        HISTORICAL_TOPICS = %w(report_updates community_news city_service_alerts komsiluk_urgent komsiluk_board).freeze
        CHANNELS = %w(topic viber whatsapp messenger instagram bell).freeze

        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id, optional: true

        validates :topic, inclusion: { in: (Preference::TOPICS + HISTORICAL_TOPICS).uniq }
        validates :channel, inclusion: { in: CHANNELS }
        validates :new_state, inclusion: { in: Preference::STATES }
        validates :previous_state, inclusion: { in: Preference::STATES }, allow_nil: true
        validates :source, inclusion: { in: SOURCES }
        validates :previous_source, inclusion: { in: SOURCES }, allow_nil: true
        validates :actor_type, inclusion: { in: ACTOR_TYPES }
        validates :operation, inclusion: { in: OPERATIONS }
        validates :change_id, :policy_version, :recorded_at, presence: true

        # Append-only: a persisted event can be read and never rewritten. An
        # audit trail that a later writer can edit is not an audit trail.
        def readonly?
          persisted?
        end
      end
    end
  end
end

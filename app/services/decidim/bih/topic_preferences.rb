# frozen_string_literal: true

module Decidim
  module Bih
    # Four citizen choices governing proactive delivery. Transport availability,
    # provider refusals and the always-available inbox have separate owners.
    module TopicPreferences
      TOPICS = %w(report_updates community_news platform_news neighborhood_info).freeze
      ALIASES = {
        "city_service_alerts" => "neighborhood_info",
        "komsiluk_urgent" => "neighborhood_info",
        "komsiluk_board" => "neighborhood_info"
      }.freeze
      POLICY_VERSION = "mi-topics-2026-09-15"
      SOURCES = %w(account organization_default legacy_import unknown).freeze

      module_function

      def canonical_topic(topic)
        value = ALIASES.fetch(topic.to_s, topic.to_s)
        raise ArgumentError, "unknown notification topic" unless TOPICS.include?(value)

        value
      end

      def topic_for(topic) = canonical_topic(topic)

      def normalize_topic(topic) = canonical_topic(topic)

      def enabled?(user, topic:)
        topic = canonical_topic(topic)
        return true unless user && user.respond_to?(:id) && user.id

        preference = Messaging::Preference.find_by(
          decidim_organization_id: user.decidim_organization_id,
          decidim_user_id: user.id, topic:
        )
        preference.nil? || preference.allowed?
      end

      def set!(user, topic:, enabled:, source: "account")
        topic = canonical_topic(topic)
        value = boolean(enabled)
        raise ArgumentError, "invalid topic preference source" unless SOURCES.include?(source.to_s)

        user.with_lock { write!(user, topic:, enabled: value, source: source.to_s) }
      end

      def set_all!(user, enabled:, source: "account")
        value = boolean(enabled)
        raise ArgumentError, "invalid topic preference source" unless SOURCES.include?(source.to_s)

        user.with_lock do
          TOPICS.each { |topic| write!(user, topic:, enabled: value, source: source.to_s) }
        end
      end

      def boolean(value)
        return true if [true, "1", "true", "TRUE", 1].include?(value)
        return false if [false, "0", "false", "FALSE", 0].include?(value)

        raise ArgumentError, "notification preference must be boolean"
      end

      def write!(user, topic:, enabled:, source:)
        record = Messaging::Preference.find_or_initialize_by(
          organization: user.organization, user:, topic:
        )
        state = enabled ? "allowed" : "blocked"
        return record if record.persisted? && record.state == state && record.source == source

        previous_state = record.persisted? ? record.state : nil
        previous_source = record.persisted? ? record.source : nil
        change_id = SecureRandom.uuid
        changed_at = Time.current
        record.update!(state:, source:, policy_version: POLICY_VERSION, change_id:, changed_at:, imported_from: nil)
        Messaging::PreferenceChange.create!(
          organization: user.organization, user:, topic:, channel: "topic",
          previous_state:, new_state: state, previous_source:, source:,
          actor_type: actor_type(source),
          actor_id: source == "account" ? user.id : nil,
          operation: operation(source),
          change_id:, policy_version: POLICY_VERSION, recorded_at: changed_at
        )
        record
      end

      def actor_type(source)
        return "citizen" if source == "account"
        return "organization_policy" if source == "organization_default"

        "system_import"
      end

      def operation(source)
        return "set" if source == "account"
        return "organization_default" if source == "organization_default"

        "import"
      end
      private_class_method :write!, :actor_type, :operation
    end
  end
end

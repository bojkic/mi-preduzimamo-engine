# frozen_string_literal: true

module Decidim
  module Bih
    # Frozen transformation for the 20260915 migration. It does not resolve
    # delivery or run during a settings read. Keep old values in history, and
    # collapse a stored refusal conservatively across channels of that topic.
    module TopicPreferenceMigration
      TOPICS = %w(report_updates community_news platform_news neighborhood_info).freeze
      CHANNELS = %w(viber whatsapp messenger instagram).freeze
      MATRIX_TOPICS = %w(report_updates community_news city_service_alerts).freeze
      KEY_TOPICS = MATRIX_TOPICS.each_with_object({}) do |topic, keys|
        CHANNELS.each do |channel|
          keys["mi_#{topic}_#{channel}"] = topic == "city_service_alerts" ? "neighborhood_info" : topic
        end
      end.merge("mi_komsiluk_urgent_bell" => "neighborhood_info", "komsiluk_board" => "neighborhood_info").freeze
      PROVENANCE_KEY = "mi_channel_preference_provenance"
      SOURCES = %w(account provider_opt_out organization_default legacy_import unknown).freeze

      module_function

      def snapshot(settings:, preferences:)
        entries = json_entries(settings) + preferences.map { |row| row_entry(row) }
        choices = TOPICS.to_h { |topic| [topic, choice_for(topic, entries)] } # rubocop:disable Rails/IndexWith -- This migration transform also runs without Rails.
        { choices:, entries:, provider_blocks: entries.select { |entry| entry[:source] == "provider_opt_out" && entry[:state] == "blocked" } }
      end

      def choice_for(topic, entries)
        candidates = entries.select { |entry| entry[:topic] == topic && entry[:source] != "provider_opt_out" }
        blocked = candidates.select { |entry| entry[:state] == "blocked" }
        selected = (blocked.empty? ? candidates : blocked).max_by { |entry| source_priority(entry[:source]) }
        selected || { topic:, state: "allowed", source: "organization_default" }
      end

      def cleaned_settings(settings)
        settings.reject { |key, _value| KEY_TOPICS.has_key?(key) || key == PROVENANCE_KEY }
      end

      def json_entries(settings)
        provenance = settings.fetch(PROVENANCE_KEY, {})
        KEY_TOPICS.filter_map do |key, topic|
          next unless settings.has_key?(key)

          origin = provenance.fetch(key, {})
          {
            topic:, legacy_topic: legacy_topic(key), channel: channel(key),
            state: state(settings[key]), source: source(origin["source"]),
            changed_at: origin["changed_at"], change_id: origin["change_id"], imported_from: key
          }
        end
      end

      def row_entry(row)
        raw_topic = row.fetch("topic")
        {
          topic: raw_topic == "city_service_alerts" ? "neighborhood_info" : raw_topic,
          legacy_topic: raw_topic, channel: row.fetch("channel"),
          state: row.fetch("state"), source: source(row["source"]),
          changed_at: row["changed_at"], change_id: row["change_id"], imported_from: "messaging_preferences"
        }
      end

      def state(value)
        return "allowed" if [true, "1", "true", "TRUE", 1].include?(value)
        return "blocked" if [false, "0", "false", "FALSE", 0].include?(value)

        raise ArgumentError, "invalid legacy notification preference value"
      end

      def source(value)
        SOURCES.include?(value.to_s) ? value.to_s : "unknown"
      end

      def source_priority(value)
        { "account" => 4, "unknown" => 3, "legacy_import" => 2, "organization_default" => 1 }.fetch(value, 0)
      end

      def channel(key)
        return "bell" if %w(komsiluk_board mi_komsiluk_urgent_bell).include?(key)

        key.split("_").last
      end

      def legacy_topic(key)
        return "komsiluk_urgent" if key == "mi_komsiluk_urgent_bell"
        return "komsiluk_board" if key == "komsiluk_board"

        MATRIX_TOPICS.find { |topic| key.start_with?("mi_#{topic}_") }
      end
    end
  end
end

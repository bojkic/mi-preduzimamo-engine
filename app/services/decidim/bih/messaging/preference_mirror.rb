# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Compatibility for callers of the former matrix writer. Current state
      # has one owner: TopicPreferences. No matrix value is persisted here.
      module PreferenceMirror
        POLICY_VERSION = TopicPreferences::POLICY_VERSION
        PROVENANCE_KEY = "mi_channel_preference_provenance"
        MIRRORED_KEYS = %w(report_updates community_news city_service_alerts).flat_map do |topic|
          %w(viber whatsapp messenger instagram).map { |channel| ["mi_#{topic}_#{channel}", [topic, channel]] }
        end.to_h.freeze

        module_function

        def mirrored_key?(setting_key)
          MIRRORED_KEYS.has_key?(setting_key.to_s)
        end

        # Metadata remains accepted while older callers transition. Provider
        # STOP belongs to TransportSuppression and cannot disable every channel.
        def record!(user:, topic:, enabled:, source:, **_metadata)
          return if source.to_s == "provider_opt_out"

          TopicPreferences.set!(user, topic:, enabled:, source: recognized_source(source))
        end

        def mirror_changes!(user:, previous:, default_source:, **_metadata)
          current = user.notification_settings.to_h
          changed = changed_entries(current:, previous:, default_source:)
          changed.group_by(&:first).each do |topic, entries|
            enabled = entries.all? { |entry| entry[1] }
            selected = entries.find { |entry| entry[1] == enabled }
            TopicPreferences.set!(user, topic:, enabled:, source: selected[2])
          end
          clean = current.except(*MIRRORED_KEYS.keys, PROVENANCE_KEY)
          user.update!(notification_settings: clean) if clean != current
        end

        def changed_entries(current:, previous:, default_source:)
          provenance = current.fetch(PROVENANCE_KEY, {})
          MIRRORED_KEYS.filter_map do |key, (topic, _channel)|
            next unless current.has_key?(key)
            next if previous.has_key?(key) && previous[key] == current[key]

            source = provenance.fetch(key, {}).fetch("source", default_source)
            next if source == "provider_opt_out"

            [topic, TopicPreferences.boolean(current[key]), recognized_source(source)]
          end
        end

        def recognized_source(source)
          TopicPreferences::SOURCES.include?(source.to_s) ? source.to_s : "unknown"
        end
      end
    end
  end
end

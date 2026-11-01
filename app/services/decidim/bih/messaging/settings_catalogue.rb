# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      module SettingsCatalogue
        ROWS = TopicPreferences::TOPICS.map do |topic|
          { id: topic.to_sym, section: :topics, kind: :bool, topic: topic.to_sym }.freeze
        end.freeze

        module_function

        def for(_user) = ROWS

        def writable(_user) = ROWS

        def find(id) = ROWS.find { |row| row[:id] == id.to_sym }

        def registry_rows(user)
          return [] unless user.moderator? && Decidim.respond_to?(:notification_settings_registry)

          Decidim.notification_settings_registry.manifests
                 .select { |manifest| manifest.settings_area == :administrators }
                 .map { |manifest| { id: manifest.name.to_sym, registry_manifest: manifest } }
        end
      end
    end
  end
end

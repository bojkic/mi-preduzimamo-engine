# frozen_string_literal: true

module Decidim
  module Bih
    # Missing fields stay nil, so a partial save never opts out other topics.
    class CommunicationSettingsForm < Decidim::Form
      mimic :communication_settings
      attribute :rendered_rows, [String]
      TopicPreferences::TOPICS.each do |topic|
        attribute topic, Decidim::AttributeObject::TypeMap::Boolean
      end

      def submitted_rows
        topics = TopicPreferences::TOPICS.select { |topic| value_submitted?(topic) }
        declared = Array(rendered_rows)
        (declared.any? ? topics & declared : topics).map(&:to_sym)
      end

      def value_submitted?(id)
        TopicPreferences::TOPICS.include?(id.to_s) && !public_send(id).nil?
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module ReportDetails
      CHOICES = { 'observed_since' => %w(danas tjedan mjesec duze), 'recurrence' => %w(jednom povremeno stalno pri_kisi),
                  'hazard' => %w(nema moguca ozbiljna), 'kind' => %w(kvar prijedlog) }.freeze
      module_function
      def valid?(details)
        details.is_a?(Hash) && (details.keys - (CHOICES.keys + ['whole_city'])).empty? && details.all? do |key, value|
          key == 'whole_city' ? [true, false].include?(value) : CHOICES.fetch(key).include?(value)
        end
      end
      def normalize(details)
        return { "invalid" => true } unless details.respond_to?(:to_h)
        result = details.to_h.stringify_keys.reject { |_, value| value.blank? }
        result['whole_city'] = ActiveModel::Type::Boolean.new.cast(result['whole_city']) if result.key?('whole_city')
        result
      end
    end
  end
end

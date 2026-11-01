# frozen_string_literal: true

module Decidim
  module Bih
    module ReportTexts
      QUESTIONS = %w(exact_location landmark extent since_when recurring safety_risk property_owner photo_helpful access_blocked).freeze
      SERVICE = %w(supplement answer_city remind_city city_answered city_planned city_reports_resolved).freeze
      KEYS = (QUESTIONS + SERVICE).freeze
      SLOTS = { 'supplement' => %w(text), 'answer_city' => %w(text), 'city_answered' => %w(text),
                'city_planned' => %w(text date), 'city_reports_resolved' => %w(text) }.freeze
      Invalid = Class.new(ArgumentError)
      module_function
      def render(key, slots: {}, locale: :sr)
        raise Invalid, 'unknown_template' unless KEYS.include?(key.to_s)
        slots = slots.stringify_keys
        raise Invalid, 'unknown_slots' unless slots.keys.sort == SLOTS.fetch(key.to_s, []).sort
        raise Invalid, 'unsafe_slot' unless slots.values.all? { |value| safe_text?(value.to_s, attributed: true) }
        text = I18n.t("decidim.bih.report_questions.#{key}", locale: locale.to_s == 'sr-Cyrl' ? :sr : locale,
                      **slots.symbolize_keys, raise: true)
        locale.to_s == 'sr-Cyrl' ? Transliterator.call(text) : text
      end
      def safe_text?(text, attributed: false)
        return false unless text.is_a?(String) && text.length <= 600 && !text.match?(/[\p{Cyrillic}]/)
        contact_text = attributed ? text.gsub(/\b(?:0?[1-9]|[12]\d|3[01])\.(?:0?[1-9]|1[0-2])\.\d{4}\.?/, '[quoted_date]') : text
        return false if contact_text.match?(%r{https?://|www\.|[\w.+-]+@[\w.-]+|(?:\+?\d[\s()-]*){7,}})
        return false if text.match?(/riješi[ćc]emo|poslali smo|zaprimila je|do \d|rok je|biće riješeno|bi[ćc]e riješeno/i)
        return false if !attributed && text.match?(/služba|grad je|policija/i) && !text.start_with?('Služba je odgovorila:', 'Služba navodi:')
        true
      end
      def composed!(text, context:)
        raise Invalid, 'unsafe_composed_text' unless safe_text?(text) && context.redact(text) == text
        text
      end
    end
  end
end

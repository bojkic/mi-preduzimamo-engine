# frozen_string_literal: true

# rubocop:disable Layout/LineLength -- explicit schema and correlated SQL guards kept together

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- explicit independent policy and safety guards

module Decidim
  module Bih
    module Ai
      class ProposalValidators
        Invalid = Class.new(StandardError) do
          attr_reader :reason, :diagnostic

          def initialize(reason, path: nil)
            @reason = reason
            @diagnostic = [reason, path].compact.join(": ")
            super(reason)
          end
        end
        OBLIGATIONS = %w(review dispatch_approval closure_approval info_request evidence_collection evidence_handoff city_response city_commitment mail_review dispute_review
                         delivery_exception).freeze
        def validate!(raw, context)
          @context = context
          shape!(raw, CaseDecision::SCHEMA)
          refuse!("schema") if raw.to_json.bytesize > 24_000
          refuse!("action_not_allowed") unless CaseDecision::ACTIONS.include?(raw["proposed_action"])
          refuse!("contact_in_output") unless context.redact(raw.to_json) == raw.to_json
          # Model dates must be quoted strings from a service message. There is
          # no due date, confidence percentage or free-form metadata escape hatch.
          raw["facts"].each_with_index do |fact, index|
            source = context.sources[fact["source_id"]]
            refuse!("fact_not_quoted", path: "facts[#{index}]") unless source && fact["text"] == fact["quote"] && fact["quote"].present? && source.include?(fact["quote"])
          end
          raw["observations"].each do |obs|
            refuse!("observation_source_not_in_evidence_items") unless context.data[:evidence_items].any? do |item|
              "evidence:#{item[:id]}" == obs["source_id"]
            end
          end
          route = raw["routing"]
          refuse!("schema") unless context.data[:categories].include?(route["category"])
          refuse!("unknown_recipient") if route["recipient_key"].present? && context.data.fetch(:approved_recipient_keys).exclude?(route["recipient_key"])
          if route["guidance_key"].present?
            guide = context.data[:routing_guidance].find { |g| g[:key] == route["guidance_key"] }
            unless guide && guide[:categories].include?(route["category"]) && (route["recipient_key"].blank? || guide[:approved_recipient_keys].include?(route["recipient_key"]))
              refuse!("unknown_guidance")
            end
          end
          ids = context.data[:open_obligations].map { |item| item[:id] }
          raw["obligation_updates"].each do |update|
            refuse!("unknown_obligation_id") unless update["obligation_id"].zero? || ids.include?(update["obligation_id"])
            refuse!("unknown_obligation_kind") unless update["new_kind"].blank? || OBLIGATIONS.include?(update["new_kind"])
            refuse!("invalid_new_obligation") if update["obligation_id"].zero? && (update["action"] != "open" || update["new_kind"].blank?)
          end
          raw["missing_fields"].each_with_index do |missing, index|
            refuse!("schema") unless CaseDecision::FIELDS.include?(missing["field"])
            refuse!("fact_not_quoted", path: "missing_fields[#{index}].why_quote") unless context.sources.values.any? do |source|
              missing["why_quote"].present? && source.include?(missing["why_quote"])
            end
            refuse!("question_mismatch") if missing["field"] == "photo_helpful" && missing["required"]
          end
          message = raw["citizen_message"]
          refuse!("question_mismatch") if message["template_key"].present? && message["composed_text"].present?
          if message["template_key"].present?
            slots = message["slots"].compact_blank
            ReportTexts.render(message["template_key"], slots:)
          end
          ReportTexts.composed!(message["composed_text"], context:) if message["composed_text"].present?
          if (raw["proposed_action"] == "wait") && (message["template_key"].present? || message["composed_text"].present? || raw["city_message"]["text"].present? || raw["obligation_updates"].any?)
            refuse!("wait_has_effects")
          end
          if (raw["proposed_action"] == "ask") && !(raw["missing_fields"].any? do |field|
            field["required"]
          end && (message["template_key"].present? || message["composed_text"].present?))
            refuse!("question_mismatch")
          end
          ids = context.data[:evidence_items].map { |item| item[:id] }
          refuse!("unknown_evidence") unless (raw["city_message"]["evidence_item_ids"] - ids).empty?
          ReportTexts.composed!(raw["city_message"]["text"], context:) if raw["city_message"]["text"].present?
          response = raw["service_response"]
          if response["quote"].present? && context.data[:correspondence].none? { |mail| mail[:text].include?(response["quote"]) }
            refuse!("fact_not_quoted", path: "service_response.quote")
          end
          if response["planned_date_quote"].present? && !(response["type"] == "work_planned" && response["quote"].include?(response["planned_date_quote"]))
            refuse!("fact_not_quoted",
                    path: "service_response.planned_date_quote")
          end
          if message.dig("slots",
                         "date").present? && !(message["template_key"] == "city_planned" && message["slots"]["date"] == response["planned_date_quote"] && response["quote"].include?(message["slots"]["date"]))
            refuse!("fact_not_quoted")
          end
          response["requested_evidence"].each do |request|
            refuse!("fact_not_quoted") unless request.present? && response["quote"].include?(request)
          end
          response["file_numbers"].each do |number|
            refuse!("fact_not_quoted", path: "service_response.file_numbers") unless number.present? && context.data[:correspondence].any? { |mail| mail[:text].include?(number) }
          end
          assessment = raw["assessment"]
          refuse!("fact_not_quoted") if assessment["hazard_signal"] && context.sources.values.none? do |text|
            assessment["hazard_quote"].present? && text.include?(assessment["hazard_quote"])
          end
          duplicate = raw["duplicate"]
          if raw["proposed_action"] == "duplicate"
            candidate = context.data[:candidates].find { |item| item[:reference] == duplicate["reference"] }
            refuse!("unknown_duplicate") unless candidate && context.sources["original"].include?(duplicate["quote_new"]) && duplicate["quote_new"].present? && duplicate["quote_existing"].present? && candidate[:evidence].any? do |item|
              item[:text].include?(duplicate["quote_existing"])
            end
          end
          CaseDecision.new(raw)
        rescue ReportTexts::Invalid, I18n::MissingTranslationData
          refuse!("question_mismatch")
        end

        private

        def refuse!(code, path: nil) = raise Invalid.new(code, path:)

        def shape!(value, schema)
          case schema[:type]
          when "object"
            refuse!("schema") unless value.is_a?(Hash) && value.keys.sort == schema[:required].sort
            schema[:properties].each { |key, child| shape!(value[key.to_s], child) }
          when "array"
            refuse!("schema") unless value.is_a?(Array) && value.length <= 30
            value.each { |item| shape!(item, schema[:items]) }
          when "string" then refuse!("schema") unless value.is_a?(String) && value.length <= 3000
          when "integer" then refuse!("schema") unless value.is_a?(Integer) && value >= 0
          when "boolean" then refuse!("schema") unless value == true || value == false
          end
          refuse!("schema") if schema[:enum] && schema[:enum].exclude?(value)
        end
      end
    end
  end
end

# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

# rubocop:enable Layout/LineLength

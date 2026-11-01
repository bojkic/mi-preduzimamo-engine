# frozen_string_literal: true

# rubocop:disable Layout/LineLength -- explicit schema and correlated SQL guards kept together

module Decidim
  module Bih
    module Ai
      class CaseDecision
        ACTIONS = %w(send_initial ask supplement answer_city resolve close duplicate review plan reopen wait).freeze
        FIELDS = %w(exact_location landmark extent since_when recurring safety_risk property_owner photo_helpful access_blocked).freeze
        RESPONSE_TYPES = %w(acknowledgement needs_evidence wrong_authority work_planned completed unclear).freeze
        STRING = { type: "string" }.freeze
        FACT = { type: "object", properties: { text: STRING, source_id: STRING, quote: STRING }, required: %w(text source_id quote) }.freeze
        def self.object(properties)
          { type: "object", properties:, required: properties.keys.map(&:to_s) }
        end
        SCHEMA = object(
          assessment: object(in_scope: { type: "boolean" }, kind: { type: "string", enum: %w(kvar prijedlog van_nadleznosti) }, hazard_signal: { type: "boolean" }, hazard_quote: STRING),
          missing_fields: { type: "array", items: object(field: { type: "string", enum: FIELDS }, required: { type: "boolean" }, why_quote: STRING) },
          citizen_message: object(template_key: STRING, composed_text: STRING, slots: object(text: STRING, date: STRING)),
          duplicate: object(reference: STRING, quote_new: STRING, quote_existing: STRING),
          routing: object(category: STRING, recipient_key: STRING, guidance_key: STRING),
          city_message: object(kind: { type: "string", enum: %w(initial supplement answer followup) }, text: STRING, evidence_item_ids: { type: "array", items: { type: "integer" } }),
          service_response: object(type: { type: "string", enum: RESPONSE_TYPES }, quote: STRING, planned_date_quote: STRING, file_numbers: { type: "array", items: STRING }, requested_evidence: { type: "array", items: STRING }),
          proposed_action: { type: "string", enum: ACTIONS },
          obligation_updates: { type: "array", items: object(obligation_id: { type: "integer" }, new_kind: STRING, action: { type: "string", enum: %w(open fulfil supersede) }) },
          facts: { type: "array", items: FACT },
          observations: { type: "array", items: object(source_id: STRING, statement: STRING) },
          rationale: STRING, uncertainties: { type: "array", items: STRING }
        ).freeze
        def self.schema_for(context)
          schema = SCHEMA.deep_dup
          ids = context.data.fetch(:evidence_items).map { |item| "evidence:#{item[:id]}" }
          observations = schema[:properties][:observations]
          if ids.empty?
            observations[:maxItems] = 0
          else
            observations[:items][:properties][:source_id] = { type: "string", enum: ids }
          end
          updates = schema[:properties][:obligation_updates][:items][:properties]
          updates[:obligation_id] = { type: "integer", minimum: 0, maximum: context.data.fetch(:open_obligations).filter_map { |item| item[:id] }.max || 0 }
          updates[:new_kind] = { type: "string", enum: ProposalValidators::OBLIGATIONS }
          schema
        end

        def initialize(value) = @value = value

        def to_h = @value

        def [](key) = @value[key.to_s]
      end
    end
  end
end

# rubocop:enable Layout/LineLength

# frozen_string_literal: true

require "json"
require_relative "contracts"
require_relative "evidence_envelope"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Closed, server-registered public reads. No constantize/send, arbitrary
        # network address, actor identity or action confirmation from model JSON.
        class ReadToolRegistry
          RESERVED_ARGUMENTS = %w(actor_id user_id organization_id tenant_id conversation_key capabilities deadline confirmed confirmation sql url endpoint).freeze
          SCHEMA_KEYS = {
            "object" => %w(type description properties required additionalProperties),
            "array" => %w(type description items minItems maxItems),
            "string" => %w(type description enum minLength maxLength),
            "integer" => %w(type description enum minimum maximum),
            "number" => %w(type description enum minimum maximum),
            "boolean" => %w(type description enum)
          }.freeze
          TYPES = %w(object array string integer number boolean).freeze

          def initialize(definitions:)
            raise Contracts::Invalid, "Read definitions required" unless definitions.is_a?(Array) && definitions.size.between?(1, 32)

            @tools = definitions.to_h do |definition|
              build_definition(definition)
            end.freeze
            raise Contracts::Invalid, "Duplicate read name" unless @tools.size == definitions.size
          rescue KeyError, JSON::GeneratorError, JSON::ParserError
            raise Contracts::Invalid, "Incomplete read definition"
          end

          def declarations
            @tools.values.map { |tool| tool.fetch(:declaration) }.freeze
          end

          def call(name:, arguments:, context:, eligibility:)
            trusted_context!(context)
            arguments = validate_call!(name: name, arguments: arguments)
            result = @tools.fetch(name).fetch(:handler).call(arguments: arguments, context: context)
            trusted_context!(context)
            raise Contracts::Invalid, "Typed evidence required" unless result.is_a?(EvidenceEnvelope)

            result.for_prompt(context: context, eligibility: eligibility)
            result
          end

          # Validate without executing, also usable for server-only proposals.
          def validate_call!(name:, arguments:)
            tool = @tools[name]
            raise Contracts::Invalid, "Unknown public read" unless tool

            validate_arguments!(arguments, tool.fetch(:declaration).fetch("parameters"))
            raise Contracts::Invalid, "Read arguments exceeded" if JSON.generate(arguments).bytesize > 16_384

            Contracts.snapshot(arguments)
          end

          private

          def trusted_context!(context)
            raise Contracts::Invalid, "Trusted public read context required" unless context.is_a?(Contracts::TrustedContext) && context.allows?("public_reads")
            raise Contracts::Invalid, "Read deadline required" unless context.deadline && !context.deadline.expired?
          end

          def build_definition(definition)
            spec = Contracts.object!(definition, %w(name description parameters handler))
            name = Contracts.text!(spec.fetch("name"), limit: 64)
            raise Contracts::Invalid, "Invalid read name" unless name.match?(/\A[a-z][a-z0-9_]*\z/)

            description = Contracts.text!(spec.fetch("description"), limit: 1000)
            schema = JSON.parse(JSON.generate(spec.fetch("parameters")))
            validate_schema!(schema)
            raise Contracts::Invalid, "Top-level object required" unless schema.fetch("type") == "object"

            handler = spec.fetch("handler")
            raise Contracts::Invalid, "Read handler required" unless handler.respond_to?(:call)

            [name, { declaration: freeze_schema({ "name" => name, "description" => description, "parameters" => schema }), handler: handler }.freeze]
          end

          # Schema validation already bounds logical depth. Unlike argument
          # snapshots, JSON Schema adds properties/items wrapper levels.
          def freeze_schema(value)
            case value
            when Hash then value.each do |key, item|
              freeze_schema(key)
              freeze_schema(item)
            end
            when Array then value.each { |item| freeze_schema(item) }
            end
            value.freeze
          end

          def validate_schema!(schema, depth = 0) # rubocop:disable Metrics/CyclomaticComplexity
            unless schema.is_a?(Hash) && depth <= 4 && TYPES.include?(schema["type"]) && (schema.keys - SCHEMA_KEYS.fetch(schema["type"])).empty?
              raise Contracts::Invalid,
                    "Invalid read schema"
            end

            validate_schema_constraints!(schema)
            case schema["type"]
            when "object" then validate_object_schema!(schema, depth)
            when "array"
              raise Contracts::Invalid, "Bounded read array required" unless schema["maxItems"].is_a?(Integer) && schema["maxItems"].between?(1, 40)

              validate_schema!(schema.fetch("items"), depth + 1)
            when "string"
              raise Contracts::Invalid, "Bounded read text required" unless schema["maxLength"].is_a?(Integer) && schema["maxLength"].between?(1, 2000)
            end
          end

          def validate_schema_constraints!(schema)
            validate_length_bounds!(schema)
            validate_numeric_bounds!(schema)
            return unless schema.has_key?("enum")

            choices = schema.fetch("enum")
            raise Contracts::Invalid, "Typed read choices required" unless choices.is_a?(Array) && choices.size.between?(1, 40)
            raise Contracts::Invalid, "Invalid read choice schema" unless choices.all? { |choice| valid_type?(choice, schema) }
          end

          def validate_length_bounds!(schema)
            %w(minLength minItems).each do |key|
              next unless schema.has_key?(key)

              maximum = schema.fetch(key.sub("min", "max"))
              raise Contracts::Invalid, "Invalid read length bound" unless schema[key].is_a?(Integer) && maximum.is_a?(Integer) && schema[key].between?(0, maximum)
            end
          end

          def validate_numeric_bounds!(schema)
            %w(minimum maximum).each do |key|
              next unless schema.has_key?(key)

              bound = schema.fetch(key)
              raise Contracts::Invalid, "Finite numeric bound required" unless bound.is_a?(Numeric) && bound.finite?
            end
            raise Contracts::Invalid, "Invalid numeric range" if schema.has_key?("minimum") && schema.has_key?("maximum") && schema["minimum"] > schema["maximum"]
          end

          def validate_object_schema!(schema, depth)
            properties = schema.fetch("properties")
            required = schema.fetch("required", [])
            raise Contracts::Invalid, "Closed read schema required" unless schema["additionalProperties"] == false && properties.is_a?(Hash) && properties.size <= 24
            raise Contracts::Invalid, "Invalid required read fields" unless required.is_a?(Array) && (required - properties.keys).empty? && required.uniq == required
            raise Contracts::Invalid, "Authority is not a read argument" if properties.keys.intersect?(RESERVED_ARGUMENTS)

            properties.each_value { |child| validate_schema!(child, depth + 1) }
          end

          def validate_arguments!(value, schema)
            raise Contracts::Invalid, "Invalid read arguments" unless valid_type?(value, schema)

            validate_constraints!(value, schema)
            case schema.fetch("type")
            when "object" then value.each { |key, item| validate_arguments!(item, schema.fetch("properties").fetch(key)) }
            when "array" then value.each { |item| validate_arguments!(item, schema.fetch("items")) }
            when "string" then Contracts.text!(value, limit: schema.fetch("maxLength"))
            end
          end

          def validate_constraints!(value, schema)
            if schema.has_key?("enum")
              raise Contracts::Invalid, "Invalid read choice" unless schema.fetch("enum").include?(value) # rubocop:disable Style/SoleNestedConditional -- keep standalone Ruby without Array#exclude?
            end
            raise Contracts::Invalid, "Read value below minimum" if schema.has_key?("minimum") && value < schema.fetch("minimum")
            raise Contracts::Invalid, "Read value above maximum" if schema.has_key?("maximum") && value > schema.fetch("maximum")
          end

          def valid_type?(value, schema)
            case schema.fetch("type")
            when "object" then valid_object?(value, schema)
            when "array" then valid_collection?(value, schema)
            when "string" then valid_text?(value, schema)
            when "integer" then value.is_a?(Integer)
            when "number" then value.is_a?(Numeric) && value.finite?
            when "boolean" then [true, false].include?(value)
            end
          end

          def valid_object?(value, schema)
            value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) } &&
              (value.keys - schema.fetch("properties").keys).empty? &&
              (schema.fetch("required", []) - value.keys).empty?
          end

          def valid_collection?(value, schema)
            value.is_a?(Array) && value.size.between?(schema.fetch("minItems", 0), schema.fetch("maxItems"))
          end

          def valid_text?(value, schema)
            value.is_a?(String) && value.valid_encoding? && value.length.between?(schema.fetch("minLength", 0), schema.fetch("maxLength"))
          end
        end
      end
    end
  end
end

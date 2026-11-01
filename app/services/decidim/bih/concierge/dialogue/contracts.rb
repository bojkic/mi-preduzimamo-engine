# frozen_string_literal: true

require "time"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Trust-boundary value objects. Provider JSON is a proposal, never an
        # identity, permission, confirmation, SQL query or executable command.
        module Contracts
          VERSION = 1
          CONTEXT_TTL = 30 * 60
          MAX_TURNS = 6 # A turn is one citizen message and its assistant reply.
          MAX_MESSAGE_LENGTH = 2000
          ACTIONS = %w(
            ask_information report_problem registration sign_in link_account
            verification choose_area change_area preferences report_status neighborhood_post
            neighborhood_information help safety cancel
          ).freeze
          TOPICS = %w(
            waste water electricity transport parking heating roads city_service
            neighborhood account report donation budget gazette goodwill launch
            participation volunteer privacy unknown air_quality water_levels police sistem48 weather civil_protection bulky_waste
            community public_calls facilities rewards
            health social_welfare agriculture permits education animals
          ).freeze
          OPERATIONS = %w(start continue correct switch cancel clarify).freeze
          LOCALES = %w(sr sr-Cyrl bs hr en).freeze
          ENTITY_KEYS = %w(
            area_query area_slug street address time_expression date route stop via_stop transfer_mode
            description category query reference
          ).freeze
          READ_STATUSES = %w(ok empty ambiguous unavailable not_authorized stale unreviewed).freeze
          ACCOUNT_STATES = %w(anonymous unregistered registered unverified verified unavailable).freeze
          CAPABILITIES = %w(
            public_reads neighborhood_reads own_report_reads report_guidance
            registration_handoff write_report write_neighborhood
          ).freeze

          class Invalid < ArgumentError; end

          module_function

          def enum!(value, allowed)
            raise Invalid, "Unsupported contract enum" unless value.is_a?(String) && allowed.include?(value)

            value.dup.freeze
          end

          def action_topic!(action, topic, allow_nil_action: false)
            validated_action = if action.nil? && allow_nil_action
                                 nil
                               else
                                 enum!(action, ACTIONS)
                               end
            validated_topic = enum!(topic, TOPICS)
            raise Invalid, "Area change requires account topic" if validated_action == "change_area" && validated_topic != "account"

            [validated_action, validated_topic]
          end

          def object!(value, keys)
            raise Invalid, "Expected contract object" unless value.is_a?(Hash)

            normalized = value.transform_keys(&:to_s)
            raise Invalid, "Duplicate contract keys" unless normalized.size == value.size
            raise Invalid, "Unexpected contract field" unless (normalized.keys - keys).empty?

            normalized
          end

          def text!(value, limit: MAX_MESSAGE_LENGTH)
            raise Invalid, "Expected bounded contract text" unless value.is_a?(String) && value.valid_encoding? && value.length <= limit
            raise Invalid, "Contract text contains control characters" if value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)

            value.dup.freeze
          end

          # Copy before freezing: never freeze a domain record or caller's hash.
          def snapshot(value, depth: 0, max_object_keys: 32)
            raise Invalid, "Contract nesting exceeded" if depth > 6

            case value
            when Hash
              raise Invalid, "Contract object too large" if value.size > max_object_keys

              value.to_h { |key, item| [text!(key.to_s, limit: 80), snapshot(item, depth: depth + 1, max_object_keys: max_object_keys)] }.freeze
            when Array
              raise Invalid, "Contract collection too large" if value.size > 40

              value.map { |item| snapshot(item, depth: depth + 1, max_object_keys: max_object_keys) }.freeze
            else scalar_snapshot(value)
            end
          end

          def scalar_snapshot(value)
            case value
            when String then text!(value)
            when Integer, TrueClass, FalseClass, NilClass then value
            when Float
              raise Invalid, "Non-finite contract number" unless value.finite?

              value
            when Time then value.dup.freeze
            else raise Invalid, "Unsupported contract value"
            end
          end

          Understanding = Data.define(:action, :topic, :entities, :operation, :needs_clarification, :secondary, :locale) do
            FIELDS = %w(action topic entities operation needs_clarification secondary locale).freeze

            def self.parse(payload)
              values = Contracts.object!(payload, FIELDS)
              raise Invalid, "Incomplete understanding" unless (FIELDS - values.keys).empty?

              entities = Contracts.object!(values.fetch("entities"), ENTITY_KEYS)
              entities = entities.to_h do |key, value|
                [key.freeze, Contracts.text!(value, limit: key == "description" ? 1000 : 160)]
              end.freeze
              clarification = values.fetch("needs_clarification")
              raise Invalid, "Clarification must be boolean" unless [true, false].include?(clarification)

              action, topic = Contracts.action_topic!(values.fetch("action"), values.fetch("topic"))

              new(
                action:,
                topic:,
                entities:,
                operation: Contracts.enum!(values.fetch("operation"), OPERATIONS),
                needs_clarification: clarification,
                secondary: parse_secondary(values.fetch("secondary")),
                locale: Contracts.enum!(values.fetch("locale"), LOCALES)
              )
            end

            def self.parse_secondary(value)
              return nil if value.nil?

              request = Contracts.object!(value, %w(action topic))
              raise Invalid, "Incomplete secondary request" unless request.keys.sort == %w(action topic)

              action, topic = Contracts.action_topic!(request.fetch("action"), request.fetch("topic"))

              { "action" => action, "topic" => topic }.freeze
            end

            def self.clarify(locale: "sr")
              parse({
                      "action" => "help", "topic" => "unknown", "entities" => {},
                      "operation" => "clarify", "needs_clarification" => true,
                      "secondary" => nil, "locale" => locale
                    })
            end
          end

          # Only server adapters construct this object. It is deliberately not
          # accepted by Understanding.parse, and never serialized into a prompt.
          TrustedContext = Data.define(:organization_id, :conversation_key, :actor_id, :account_state, :capabilities, :now, :deadline) do
            # Keep the explicit trust-boundary fields visible to every adapter.
            def initialize(organization_id:, conversation_key:, actor_id: nil, account_state: "anonymous", capabilities: [], now: Time.now.utc, deadline: nil) # rubocop:disable Metrics/ParameterLists
              validate_scope!(organization_id, conversation_key, actor_id)
              raise Invalid, "Trusted clock required" unless now.is_a?(Time)
              raise Invalid, "Invalid capabilities" unless capabilities.is_a?(Array) && capabilities.size <= CAPABILITIES.size

              super(
                organization_id:, conversation_key: conversation_key.dup.freeze, actor_id:,
                account_state: Contracts.enum!(account_state, ACCOUNT_STATES),
                capabilities: capabilities.map { |capability| Contracts.enum!(capability, CAPABILITIES) }.uniq.freeze,
                now: now.dup.freeze, deadline:
              )
            end

            def allows?(capability)
              capabilities.include?(capability.to_s)
            end

            private

            def validate_scope!(organization_id, conversation_key, actor_id)
              raise Invalid, "Organization scope required" unless organization_id.is_a?(Integer) && organization_id.positive?
              raise Invalid, "Opaque conversation scope required" unless conversation_key.is_a?(String) && conversation_key.match?(/\A[a-f0-9]{64}\z/)
              raise Invalid, "Invalid actor" unless actor_id.nil? || (actor_id.is_a?(Integer) && actor_id.positive?)
            end
          end

          ReadResult = Data.define(:status, :facts, :source, :checked_at, :coverage, :validity, :candidates, :warnings) do
            def initialize(status:, facts: [], source: nil, checked_at: nil, coverage: nil, validity: nil, candidates: [], warnings: [])
              raise Invalid, "Expected fact/candidate collections" unless facts.is_a?(Array) && candidates.is_a?(Array)
              raise Invalid, "Invalid check time" unless checked_at.nil? || checked_at.is_a?(Time)
              raise Invalid, "Unavailable result cannot assert facts" if %w(unavailable not_authorized).include?(status) && facts.any?

              super(
                status: Contracts.enum!(status, READ_STATUSES), facts: Contracts.snapshot(facts, max_object_keys: 128),
                source: Contracts.snapshot(source), checked_at: Contracts.snapshot(checked_at),
                coverage: Contracts.snapshot(coverage), validity: Contracts.snapshot(validity),
                candidates: Contracts.snapshot(candidates), warnings: Contracts.snapshot(warnings)
              )
            end
          end

          # A next-step offer is not a completion receipt. No raw OTP or token
          # belongs in metadata. Destinations are validated by the owning port.
          HandoffResult = Data.define(:account_state, :next_step, :destination, :expires_at, :resume_supported, :completed) do
            def initialize(account_state:, next_step:, destination: nil, expires_at: nil, resume_supported: false, completed: false)
              raise Invalid, "Invalid handoff expiry" unless expires_at.nil? || expires_at.is_a?(Time)
              raise Invalid, "Invalid handoff flags" unless [true, false].include?(resume_supported) && [true, false].include?(completed)

              super(
                account_state: Contracts.enum!(account_state, ACCOUNT_STATES),
                next_step: Contracts.text!(next_step, limit: 80),
                destination: destination.nil? ? nil : Contracts.text!(destination),
                expires_at: Contracts.snapshot(expires_at), resume_supported:, completed:
              )
            end
          end
        end
      end
    end
  end
end

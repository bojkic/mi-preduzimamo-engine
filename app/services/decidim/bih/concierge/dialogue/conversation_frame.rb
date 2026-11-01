# frozen_string_literal: true

require "digest"
require "json"
require_relative "contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Public conversational context, never evidence or authorization. The host
        # must approve public text before capture; shape validation cannot detect
        # arbitrary personal information. Protected turns are never captured.
        class ConversationFrame
          KEY = "model_led_frame"
          TTL = 600
          MAX_BYTES = 6500
          MAX_TURNS = 4
          FIELDS = %w(version scope expires_at history constraints).freeze
          CONSTRAINTS = %w(origin_id destination_id via_id date time route_code).freeze

          attr_reader :value

          def self.empty(context:)
            new({ "version" => 1, "scope" => scope(context), "expires_at" => context.now.to_f + TTL,
                  "history" => [], "constraints" => {} })
          end

          def self.scope(context)
            Digest::SHA256.hexdigest(JSON.generate([context.organization_id, context.actor_id, context.conversation_key]))
          end

          def self.load(value, context:)
            normalized = normalize(value, now: context.now)
            return empty(context: context) unless normalized && normalized["scope"] == scope(context)

            new(normalized)
          end

          def self.normalize(value, now:, state_expires_at: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
            return unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort && value["version"] == 1
            return unless value["scope"].is_a?(String) && value["scope"].match?(/\A[a-f0-9]{64}\z/)
            return unless value["expires_at"].is_a?(Numeric) && value["expires_at"].finite? && value["expires_at"] > now.to_f && value["expires_at"] <= now.to_f + TTL
            return unless valid_history?(value["history"]) && valid_constraints?(value["constraints"])
            return if JSON.generate(value).bytesize > MAX_BYTES

            expiry = [value["expires_at"], state_expires_at || value["expires_at"]].min
            return unless expiry > now.to_f

            Contracts.snapshot(value.merge("expires_at" => expiry))
          rescue Contracts::Invalid, JSON::GeneratorError
            nil
          end

          def self.valid_history?(history)
            history.is_a?(Array) && history.size <= MAX_TURNS && history.all? do |pair|
              pair.is_a?(Hash) && pair.keys.sort == %w(answer message) && pair.values.all? { |text| valid_text?(text, 2000) }
            end
          end

          def self.valid_constraints?(constraints)
            constraints.is_a?(Hash) && (constraints.keys - CONSTRAINTS).empty? && constraints.values.all? { |text| valid_text?(text, 160) }
          end

          def self.valid_text?(text, limit)
            text.is_a?(String) && text.valid_encoding? && text.length.between?(1, limit) && !text.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/)
          end

          def initialize(value)
            @value = Contracts.snapshot(value)
            freeze
          end

          def history
            value.fetch("history")
          end

          def constraints
            value.fetch("constraints")
          end

          # Constraints come only from an independent host policy, never model
          # summaries. The current message is the source for intentional changes.
          def append(message:, answer:, context:, constraints: self.constraints)
            raise Contracts::Invalid, "Invalid public frame" unless self.class.valid_constraints?(constraints)

            pairs = (history + [{ "message" => message, "answer" => answer }]).last(MAX_TURNS)
            candidate = self.class.empty(context: context).value.merge("history" => pairs, "constraints" => constraints)
            pairs.shift while pairs.any? && JSON.generate(candidate).bytesize > MAX_BYTES
            normalized = self.class.normalize(candidate, now: context.now)
            raise Contracts::Invalid, "Invalid public frame" unless normalized

            self.class.new(normalized)
          end

          def inspect
            "#<#{self.class.name} public_turns=#{history.size}>"
          end
          alias to_s inspect

          def pretty_print(printer)
            printer.text(inspect)
          end
        end
      end
    end
  end
end

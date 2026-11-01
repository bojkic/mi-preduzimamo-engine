# frozen_string_literal: true

require "json"
require_relative "contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Optional public conversation facts. Exact coordinates are ciphertext
        # supplied by the host; this object never decrypts or stores plaintext.
        # A malformed optional slot is dropped without invalidating the turn.
        module ConversationSlots
          KEY = "conversation_slots_v1"
          VERSION = 1
          MAX_BYTES = 2000
          FIELDS = %w(version location journey subjects script).freeze
          JOURNEY_FIELDS = %w(origin_id destination_id via_id origin_query destination_query via_query date time route_code direction query_kind).freeze
          SUBJECT_FIELDS = %w(kind id).freeze
          SCRIPT_VALUES = %w(latin cyrillic).freeze
          LOCATION_KINDS = %w(named exact address).freeze
          NAMED_FIELDS = %w(kind label place_id at).freeze
          EXACT_FIELDS = %w(kind ciphertext at expires_at).freeze
          EXACT_FIELDS_WITH_ACQUISITION = (EXACT_FIELDS + %w(acquired_at)).freeze
          # Address text is an authenticated ciphertext under the same bounded
          # optional-slot shape as a consented point; plaintext is never state.
          ADDRESS_FIELDS = EXACT_FIELDS
          module_function

          def empty
            { "version" => VERSION, "location" => nil, "journey" => nil, "subjects" => [], "script" => nil }
          end

          def normalize(value, now:, state_expires_at:)
            return nil if value.nil?
            return nil unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort && value["version"] == VERSION
            return nil if JSON.generate(value).bytesize > MAX_BYTES
            return nil unless valid_location?(value["location"], now:, state_expires_at:)
            return nil unless valid_journey?(value["journey"])
            return nil unless valid_subjects?(value["subjects"])
            return nil unless value["script"].nil? || SCRIPT_VALUES.include?(value["script"])

            Contracts.snapshot(value)
          rescue JSON::GeneratorError, Contracts::Invalid
            nil
          end

          def valid_location?(value, now:, state_expires_at:)
            return true if value.nil?
            return false unless value.is_a?(Hash) && LOCATION_KINDS.include?(value["kind"])
            fields = if value["kind"] == "named"
                       NAMED_FIELDS
                     elsif value["kind"] == "address"
                       ADDRESS_FIELDS
                     elsif value.key?("acquired_at")
                       EXACT_FIELDS_WITH_ACQUISITION
                     else
                       EXACT_FIELDS
                     end
            return false unless value.keys.sort == fields.sort
            return false unless valid_token?(value["at"], now:)
            if value["kind"] == "exact" && value.key?("acquired_at")
              acquired = value["acquired_at"]
              return false unless acquired.is_a?(Numeric) && acquired.finite? && acquired.positive? &&
                                  acquired >= value["at"] - 600 && acquired <= value["at"] + 60
            end
            if value["kind"] == "named"
              valid_text?(value["label"], 120) && valid_text?(value["place_id"], 120)
            else
              valid_text?(value["ciphertext"], 1400) &&
                valid_token?(value["expires_at"], now:, future: true) &&
                value["expires_at"] <= state_expires_at
            end
          end

          def valid_journey?(value)
            value.nil? || value.is_a?(Hash) && (value.keys - JOURNEY_FIELDS).empty? &&
              value.values.all? { |item| valid_text?(item, 120) } &&
              (!value.key?("direction") || %w(A B).include?(value["direction"]))
          end

          def valid_subjects?(value)
            value.is_a?(Array) && value.length <= 3 && value.all? do |item|
              item.is_a?(Hash) && item.keys.sort == SUBJECT_FIELDS.sort &&
                valid_text?(item["kind"], 30) && valid_text?(item["id"], 120)
            end
          end

          def valid_text?(value, limit)
            value.is_a?(String) && value.valid_encoding? && value.length.between?(1, limit) &&
              !value.match?(/[\x00-\x1f]/)
          end

          def valid_token?(value, now:, future: false)
            value.is_a?(Numeric) && value.finite? && value.positive? &&
              (future ? value > now.to_f : value <= now.to_f)
          end
        end
      end
    end
  end
end

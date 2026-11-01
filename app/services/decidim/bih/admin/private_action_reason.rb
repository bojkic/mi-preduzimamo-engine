# frozen_string_literal: true

require "decidim/bih/safe_error_metadata"

module Decidim
  module Bih
    module Admin
      # Required, bounded rationale for irreversible or compensating operator
      # actions. The sanitized value is suitable only for private audit/event
      # metadata; it must never be rendered on public citizen surfaces.
      class PrivateActionReason
        MAX_LENGTH = 500

        attr_reader :value

        def initialize(raw_value)
          @raw_value = raw_value.to_s.split.join(" ")
          @value = sanitized_value if raw_valid?
        end

        def valid?
          value.present?
        end

        def metadata
          valid? ? { private_reason: value } : {}
        end

        private

        attr_reader :raw_value

        def raw_valid?
          raw_value.present? && raw_value.length <= MAX_LENGTH
        end

        def sanitized_value
          Decidim::Bih::SafeErrorMetadata.sanitize_text(raw_value, max: MAX_LENGTH).presence
        end
      end
    end
  end
end

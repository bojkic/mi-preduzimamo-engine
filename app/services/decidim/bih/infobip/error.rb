# frozen_string_literal: true

module Decidim
  module Bih
    module Infobip
      # Raised when Infobip returns a non-success response or the transport fails.
      #
      # Only bounded, machine-readable diagnostics may travel with this error.
      # Provider response text is deliberately excluded because it can echo a
      # destination, message body or other citizen data into ActiveJob logs.
      class Error < StandardError
        SAFE_PROVIDER_TOKEN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/
        MAX_PROVIDER_TOKEN_BYTES = 80

        attr_reader :http_status, :error_code, :error_group

        def initialize(message = nil, http_status: nil, error_code: nil, error_group: nil)
          super(message)
          @http_status = normalize_http_status(http_status)
          @error_code = normalize_provider_token(error_code)
          @error_group = normalize_provider_token(error_group)
        end

        def metadata
          {
            http_status:,
            error_code:,
            error_group:
          }.compact
        end

        # Instrumentation rebuilds exceptions with a scrubbed message. Keep the
        # already-normalized diagnostics while ensuring the unsafe original
        # message and cause do not survive that reconstruction.
        def exception(message = nil)
          return self if message.nil? || message.equal?(self)

          self.class.new(message, **metadata)
        end

        # A 4xx is the provider saying "never": the request was refused and
        # nothing was queued, so a direct-SMS fallback is safe. A timeout (no
        # status at all) or a 5xx is "maybe already accepted" — Infobip may have
        # taken the whole Viber -> WhatsApp -> SMS chain before the socket gave
        # up, and an SMS on top of it bills the citizen's message twice (review
        # 2026-09-07, lane 1 H2 / lane 8 H-1). Those retry instead.
        def definitive_rejection?
          http_status.present? && (400..499).cover?(http_status)
        end

        private

        def normalize_http_status(value)
          status = Integer(value)
          status if (100..599).cover?(status)
        rescue ArgumentError, TypeError
          nil
        end

        def normalize_provider_token(value)
          token = value.to_s
          return if token.empty? || token.bytesize > MAX_PROVIDER_TOKEN_BYTES
          return unless SAFE_PROVIDER_TOKEN.match?(token)

          token.freeze
        end
      end
    end
  end
end

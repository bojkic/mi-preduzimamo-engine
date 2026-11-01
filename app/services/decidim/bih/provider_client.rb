# frozen_string_literal: true

require "faraday"

module Decidim
  module Bih
    # Shared base for every provider HTTP client in the engine. Subclasses get:
    #
    #   * A memoized Faraday connection built from `base_url` and `timeout`.
    #   * `safe_call(operation, on_error:, zero:)` — wraps a block in
    #     Instrumentation + LogRedactor error logging with three error strategies:
    #       :raise  — re-raise after logging (default; provider errors propagate)
    #       :swallow — log the error, return nil
    #       :zero   — log the error, return the `zero:` value (default: nil)
    #   * `configured?` — must be overridden in the subclass (the host needs to
    #     know whether to fall back to a dev/log path).
    #
    # The public method contracts of all existing subclasses are unchanged; this
    # base class merely consolidates the duplicated Faraday builder and the three
    # divergent error-handling patterns (Odoo raise / ImageFetcher swallow /
    # future `:zero` for aggregates).
    class ProviderClient
      DEFAULT_TIMEOUT = 10

      def initialize(base_url: nil, timeout: self.class::DEFAULT_TIMEOUT)
        @base_url = base_url
        @timeout = timeout
      end

      # Subclasses MUST override: return true when all required credentials /
      # config for a real call are present. Used by callers to decide between a
      # real send and a dev/log fallback.
      def configured?
        raise NotImplementedError, "#{self.class}#configured? is not implemented"
      end

      protected

      attr_reader :base_url, :timeout

      # Wraps +block+ in Instrumentation and LogRedactor error handling.
      #
      # +event_name+ — the AS::Notifications suffix (e.g. "odoo.rpc").
      # +payload+    — additional metadata passed to Instrumentation.
      # +on_error+   — :raise (default), :swallow, or :zero.
      # +zero+       — the value returned when on_error is :zero (default nil).
      #
      # With on_error: :raise the caller sees the full error after it has been
      # logged with LogRedactor. With :swallow / :zero the caller gets nil / the
      # zero value; the error is still logged at ERROR level.
      def safe_call(event_name, payload = {}, on_error: :raise, zero: nil, &)
        Decidim::Bih::Instrumentation.instrument(event_name, payload, &)
      rescue StandardError => e
        Decidim::Bih::LogRedactor.error_message(e).tap do |msg|
          Rails.logger.error("[#{self.class}] #{event_name} failed: #{msg}")
        end
        raise if on_error == :raise

        on_error == :zero ? zero : nil
      end

      # Builds (and memoizes) a Faraday connection to +url+ (defaults to
      # +base_url+). Subclasses may call this with an explicit URL for clients
      # that do not have a single base_url (e.g. ImageFetcher).
      def build_connection(url = base_url)
        Faraday.new(url: url) do |f|
          f.options.timeout = timeout
          f.options.open_timeout = timeout
          f.adapter Faraday.default_adapter
        end
      end

      def connection
        @connection ||= build_connection
      end
    end
  end
end

# frozen_string_literal: true

require "active_support/notifications"
require "decidim/bih/safe_error_metadata"

module Decidim
  module Bih
    # Small wrapper around ActiveSupport::Notifications for integration and job
    # observability. Payloads must stay metadata-only: no credentials, phones,
    # reporter contact data, free-text report bodies, or signed media URLs.
    module Instrumentation
      PREFIX = "decidim_bih"

      def self.instrument(event, payload = {})
        ActiveSupport::Notifications.instrument("#{PREFIX}.#{event}", payload) do |event_payload|
          result = yield event_payload
          event_payload[:success] = true unless event_payload.key?(:success)
          result
        rescue StandardError => e
          event_payload[:success] = false unless event_payload.key?(:success)
          event_payload[:error_class] ||= e.class.name
          # ActiveSupport::Notifications#instrument auto-adds :exception
          # ([class, message]) and :exception_object (the raw exception) to the
          # payload when the block raises — the raw message may contain PII
          # (e.g. an MSISDN). Strip them so no subscriber can serialize raw
          # data; only the scrubbed :error_class above survives.
          event_payload.delete(:exception)
          event_payload.delete(:exception_object)
          # cause: nil drops the original exception from the chain — otherwise
          # its raw (PII-bearing) message survives as e.cause and would be logged
          # by Sidekiq/Rails. The scrubbed class + message carry enough to debug.
          raise sanitized_exception(e), cause: nil
        end
      end

      # Returns an exception that carries a scrubbed message (and, where the
      # class allows, the original class) so that the :exception/:exception_object
      # keys ActiveSupport re-adds on raise hold metadata only. Falls back to a
      # RuntimeError when the original class can't be reconstructed from a string.
      def self.sanitized_exception(error)
        safe_message = Decidim::Bih::SafeErrorMetadata.error_message(
          error, fallback: error.class.name
        )
        begin
          rebuilt = error.exception(safe_message)
          # Exception#exception can clone an already attached cause. Passing
          # cause: nil to raise does not clear that existing chain, so rebuild
          # such an exception before it reaches logs or subscribers.
          rebuilt.cause ? error.class.new(safe_message) : rebuilt
        rescue StandardError
          RuntimeError.new(safe_message)
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Sistem48
      # Forwards a citizen report into the city's Sistem 48 via the e-mail
      # fallback channel. This is the integration seam: the platform builds a
      # report (Hash/Struct), and the report-processing job owns delivery and
      # retry visibility.
      #
      #   Decidim::Bih::Sistem48::Forwarder.new.call(report) # => true / false
      #
      # report responds to #to_h with keys: reference, category (symbol),
      # department, severity, description, address, lat, lng, photo_url and an
      # optional reporter_contact.
      class Forwarder
        attr_reader :last_error

        # Delivers the forwarding e-mail. Returns true on success, false (after
        # logging) if the mail could not be enqueued/sent, so the caller can
        # surface a friendly retry rather than crash the report flow.
        def call(report)
          payload = serializable(report)
          Decidim::Bih::Instrumentation.instrument(
            "sistem48.forward",
            provider: "sistem48",
            reference: payload[:reference] || payload["reference"],
            category: payload[:category] || payload["category"]
          ) do |event|
            @last_error = nil
            ReportMailer.report_email(payload).deliver_now
            event[:success] = true
            true
          rescue StandardError => e
            @last_error = e
            event[:success] = false
            event[:error_class] = e.class.name
            safe_message = Decidim::Bih::SafeErrorMetadata.error_message(e)

            logger.error("[Sistem48::Forwarder] failed to forward report: #{e.class}: #{safe_message}")
            false
          end
        end

        private

        # Pass the mailer a plain Hash of primitives, not a Struct/AR object:
        # Active Job serializes mailer arguments for background delivery. Keep
        # this a plain Hash so the synchronous report job can own retry state and
        # mark the report forwarded only after the mailer accepts delivery.
        def serializable(report)
          report.respond_to?(:to_h) ? report.to_h : report
        end

        def logger
          Rails.logger
        end
      end
    end
  end
end

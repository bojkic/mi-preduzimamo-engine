# frozen_string_literal: true

module Decidim
  module Bih
    # The one sender chain for every engine mailer: the host's
    # REPORTER_MAILER_FROM, then Decidim::Bih.reporter_mailer_from, then the
    # engine default.
    #
    # NEVER ENV["NOTIFICATION_EMAIL"]: no host sets it, so the three mailers
    # that used to read it (operator-role expiry, launch invitation, ops health
    # alert) sent from notifications@example.org — a domain whose SPF record is
    # "-all", which means every receiving MTA is told to reject the mail. The
    # launch invitation carries the reservation number, so that one silently
    # never arrived (review 2026-09-07, lane 5 H1).
    module SenderAddress
      DEFAULT_FROM = "notifications@example.org"

      module_function

      def call
        ENV.fetch("REPORTER_MAILER_FROM", nil).presence ||
          Decidim::Bih.reporter_mailer_from.presence ||
          DEFAULT_FROM
      end

      # Instance-side helper for mailers that `include` this module.
      def sender_address
        SenderAddress.call
      end
    end
  end
end

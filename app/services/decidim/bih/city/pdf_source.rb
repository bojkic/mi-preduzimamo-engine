# frozen_string_literal: true

require "faraday"
require "tempfile"

module Decidim
  module Bih
    module City
      # Shared, size-bounded PDF download for the City content services that fetch
      # a remote source document (Budget and WasteSchedule).
      #
      # Both services downloaded a PDF to a tempfile over Faraday with the same
      # timeout shape, but only Budget enforced a maximum body size. A wrong or
      # compromised source URL could otherwise stream an unbounded body into
      # memory and a tempfile. Consolidating the download here means the size
      # guard lives in ONE place and BOTH callers are protected by the same cap.
      #
      # Behaviour-preserving for the existing callers:
      #   * same Faraday connection (timeout == open_timeout == +timeout+),
      #   * same MAX_PDF_BYTES cap value Budget already used (25 MiB),
      #   * same failure modes (non-success status, oversize body, transport
      #     error) raised as the caller's own error class with the caller's label
      #     in the message, so "Budget PDF ..." / "Schedule PDF ..." are unchanged.
      module PdfSource
        # Cap the download so a wrong/compromised source URL can't stream an
        # unbounded body into memory and a tempfile. This is the value Budget
        # already enforced; WasteSchedule now shares it.
        MAX_PDF_BYTES = 25 * 1024 * 1024

        module_function

        # Downloads +url+ to a binary Tempfile and returns the open file (the
        # caller is responsible for #close! ing it). Raises +error_class+ on a
        # non-success status, an oversize body, or a transport error.
        #
        # +label+ prefixes the human-readable error messages ("Budget PDF",
        # "Schedule PDF"); +prefix+ names the tempfile.
        def download_to_tempfile(url:, timeout:, error_class:, label:, prefix:)
          response = connection(timeout).get(url)
          raise error_class, "#{label} returned HTTP #{response.status}" unless response.success?
          raise error_class, "#{label} too large" if response.body.to_s.bytesize > MAX_PDF_BYTES

          file = Tempfile.new([prefix, ".pdf"])
          file.binmode
          file.write(response.body)
          file.flush
          file
        rescue Faraday::Error => e
          raise error_class,
                "#{label} transport error: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end

        def connection(timeout)
          Faraday.new do |conn|
            conn.options.timeout = timeout
            conn.options.open_timeout = timeout
            conn.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end

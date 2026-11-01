# frozen_string_literal: true

require "faraday"
require "nokogiri"

module Decidim
  module Bih
    module Sistem48
      # Raised when the Sistem 48 archive cannot be fetched.
      class ScrapeError < StandardError; end

      # Scrapes a public Sistem 48 archive to surface the status of forwarded
      # reports back inside the host front-end.
      #
      # The archive has no API, so we parse the public "Pregled prijava" result
      # list. Each report renders as a `div.list-group` with three anchors:
      #   1. header  — "# <reference>" + a status label (pull-right)
      #   2. body    — "Podneta:" date, "Prijava:" text, "Odgovoreno:" date
      #   3. footer  — "<category> - <department>" (text-right)
      # Status is also encoded in the header's contextual class:
      #   success => riješena, warning => u obradi, danger => odbačena.
      #
      # Structure verified against the live site on 2026-06-07 (see the
      # matching fixture test/fixtures/files/sistem48_archive.html).
      class ArchiveScraper
        DEFAULT_TIMEOUT = 15
        DEFAULT_RETRIES = 1

        attr_reader :archive_url

        def initialize(archive_url: ENV.fetch("SISTEM48_ARCHIVE_URL", nil).presence || Decidim::Bih.sistem48_archive_url,
                       timeout: DEFAULT_TIMEOUT,
                       retries: ENV.fetch("SISTEM48_ARCHIVE_RETRIES", DEFAULT_RETRIES).to_i)
          @archive_url = archive_url
          @timeout = timeout
          @retries = [retries, 0].max
        end

        def configured?
          archive_url.present?
        end

        # Fetches and parses the archive. Returns an array of report hashes:
        # { reference:, category:, status:, location:, response_text:, date: }.
        def fetch_archive
          html = get(archive_url)
          parse(html)
        end

        # Parses already-fetched archive HTML. Exposed so callers (and tests)
        # can parse a cached/fixture document without a network round-trip.
        def parse(html)
          doc = Nokogiri::HTML(normalize_html(html), nil, "UTF-8")
          doc.css("div.list-group").filter_map { |node| parse_entry(node) }
        end

        # Returns the archive entry matching a report reference, or nil.
        # Comparison is on digits only, tolerating "# 2026056629" vs "2026056629".
        def status_for(reference:)
          wanted = digits(reference)
          return nil if wanted.empty?

          fetch_archive.find { |entry| entry[:reference] == wanted }
        end

        private

        def parse_entry(node)
          header = node.at_css("a.list-group-item.active")
          return nil unless header

          reference = digits(header.at_css("strong")&.text)
          return nil if reference.empty?

          {
            reference: reference,
            category: category_for(node),
            status: status_for_node(header),
            # Not published in the archive listing; available only on the
            # per-report detail page (prijava.php?id=).
            location: nil,
            response_text: nil,
            date: submitted_date(node)
          }
        end

        def status_for_node(header)
          status = header.at_css("p.pull-right")&.text&.strip.presence
          # Never mirror undecodable text as a citizen-facing city decision.
          raise ScrapeError, "Sistem 48 archive contains a malformed status label" if status&.match?(/[\uFFFD\u0080-\u009F]|(?:Ã|Â|Ĺ|Ä|Å)[^\s]/)

          status
        end

        def category_for(node)
          footer = node.at_css("a.text-right strong")
          footer&.text&.strip.presence
        end

        # Extracts the "Podneta:" submission date from the body anchor.
        def submitted_date(node)
          body = node.at_css("a.list-group-item.small")
          return nil unless body

          text = body.text
          match = text.match(/Podneta:\s*(.+?)(?:\n|$)/)
          match && match[1].strip
        end

        def digits(value)
          value.to_s.gsub(/\D/, "")
        end

        def get(url)
          response = with_retries { connection.get(url) }
          raise ScrapeError, "Sistem 48 archive returned HTTP #{response.status}" unless response.success?

          normalize_html(response.body)
        rescue Faraday::Error => e
          raise ScrapeError,
                "Sistem 48 archive transport error: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end

        def with_retries
          attempts = 0

          begin
            yield
          rescue Faraday::Error
            attempts += 1
            retry if attempts <= @retries

            raise
          end
        end

        def normalize_html(body)
          # The live page declares UTF-8 but contains isolated Windows-1250
          # bytes. Converting the whole document corrupts otherwise valid š/č.
          # Preserve valid UTF-8 runs and decode only malformed byte sequences.
          body.to_s.dup.force_encoding(Encoding::UTF_8).scrub do |bytes|
            bytes.dup.force_encoding("Windows-1250").encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
          end
        end

        def connection
          @connection ||= Faraday.new do |f|
            f.options.timeout = @timeout
            f.options.open_timeout = @timeout
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "faraday"
require "tempfile"

module Decidim
  module Bih
    module City
      # Raised when the waste-collection schedule cannot be fetched or parsed.
      class WasteScheduleError < StandardError; end

      # Parses an AD "Komunalac"-style annual waste-collection programme
      # ("Програм прикупљања и одвожења комуналног отпада ... за 20XX. годину")
      # into a queryable area/street -> collection-day(s) lookup, so a concierge
      # can answer "when is my street's garbage collected?".
      #
      # This is GENERIC parsing machinery: it ships NO municipal data and knows
      # no default source URL. The caller supplies the schedule text/PDF/URL
      # (via .from_text, .from_pdf, the +schedule_url+ constructor arg, or
      # #fetch). The host application owns the concrete municipality's data.
      #
      # SOURCE STRUCTURE (as published by Komunalac-format programmes): the city
      # territory is split into N districts ("Рејон 1..N"). Each district
      # renders as a 5-column table whose header row carries the weekday names:
      #
      #   Понедељак   Уторак   Сриједа   Четвртак   Петак
      #
      # and whose body rows list the streets (urban districts, headed by the
      # city name) or the villages (rural districts, headed "Села") collected on
      # that weekday. pdf-reader linearises these tables but preserves
      # approximate horizontal whitespace, so each body cell is mapped to its
      # weekday by NEAREST HEADER COLUMN OFFSET.
      #
      # Reliability is uneven, by design of the source document:
      #   * Rural / village districts have wide column gaps and parse cleanly.
      #   * Dense urban street districts sometimes separate adjacent cells by a
      #     SINGLE space, which linearised text cannot split — those rows yield
      #     best-effort / partially-merged street names.
      #
      # The parser is deliberately defensive: it extracts what is reliably
      # structured, keeps the raw extracted text available via #raw_text, and
      # never raises on malformed rows.
      class WasteSchedule
        include Decidim::Bih::City::Matching

        DEFAULT_TIMEOUT = 20

        # Collection days in Serbian (Latin), in calendar order. Returned values
        # use these canonical spellings regardless of how the PDF spelled them.
        WEEK_ORDER = %w(ponedjeljak utorak srijeda četvrtak petak subota nedjelja).freeze

        # Maps every weekday spelling that appears in the source (Cyrillic,
        # both ијекавица/екавица forms) to its canonical Latin name.
        DAY_HEADERS = {
          "Понедјељак" => "ponedjeljak", "Понедељак" => "ponedjeljak",
          "Уторак" => "utorak",
          "Сриједа" => "srijeda", "Среда" => "srijeda",
          "Четвртак" => "četvrtak",
          "Петак" => "petak",
          "Субота" => "subota",
          "Недјеља" => "nedjelja", "Недеља" => "nedjelja"
        }.freeze

        # Column-type / table labels that are never real area names and must be
        # dropped from the extracted body cells.
        STRUCTURAL_LABELS = ["Села", "Село", "РБ", "Р/б"].freeze

        # +schedule+ is the normalized lookup: area display name => array of
        # canonical day names (calendar-ordered). It is empty until something has
        # been loaded via .from_text, .from_pdf or #fetch.
        attr_reader :schedule_url, :raw_text, :schedule, :structural_labels

        # +schedule_url+ is the caller-supplied PDF URL used by #fetch; it has no
        # default because the engine ships no municipal data. +timeout+ bounds
        # the HTTP download.
        def initialize(schedule_url: nil, timeout: DEFAULT_TIMEOUT, structural_labels: STRUCTURAL_LABELS)
          @schedule_url = schedule_url
          @timeout = timeout
          @structural_labels = Array(structural_labels).map(&:to_s).freeze
          @raw_text = nil
          @schedule = {}
        end

        def self.from_text(text, structural_labels: STRUCTURAL_LABELS)
          new(structural_labels: structural_labels).load_from_text(text)
        end

        def self.from_pdf(path, structural_labels: STRUCTURAL_LABELS)
          new(structural_labels: structural_labels).load_from_pdf(path)
        end

        def configured?
          schedule_url.present?
        end

        # Parses an already-extracted block of schedule text. Idempotent;
        # returns self so callers can chain.
        def load_from_text(text)
          @raw_text = text.to_s
          @schedule = parse(@raw_text)
          self
        end

        # Extracts text from a Komunalac schedule PDF on disk, then parses it.
        # Requires the (already bundled) pdf-reader gem.
        def load_from_pdf(path)
          require "pdf/reader"
          text = PDF::Reader.new(path).pages.map(&:text).join("\n")
          load_from_text(text)
        rescue StandardError => e
          raise WasteScheduleError,
                "Could not read waste-schedule PDF: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end

        # Downloads the schedule PDF from +url+ (defaulting to the configured
        # +schedule_url+) and parses it. RAISES WasteScheduleError when the
        # source is unreachable, returns a non-success status, or cannot be
        # parsed — the engine has no data of its own to fall back to, so the
        # CALLER decides whether to degrade (e.g. by parsing a locally held
        # snapshot). Returns self on success.
        def fetch(url: schedule_url)
          raise WasteScheduleError, "No schedule URL configured" if url.blank?

          path = download_to_tempfile(url)
          load_from_pdf(path)
        ensure
          path&.close!
        end

        # All known area / street / village names (display spelling), sorted.
        def areas
          schedule.keys.sort
        end

        # Returns the collection day(s) for the area/street matching +query+, or
        # nil when nothing matches. Matching is diacritic- and script-insensitive
        # (Cyrillic or Latin) and is a fuzzy "contains" match in either
        # direction, so "glavna", "Главна" and "glavna ulica" all resolve.
        def collection_days_for(query)
          needle = normalize(query)
          return nil if needle.empty?

          exact = []
          fuzzy = []
          schedule.each do |area, area_days|
            hay = normalize(area)
            if hay == needle
              exact.concat(area_days)
            elsif hay.include?(needle) || needle.include?(hay)
              fuzzy.concat(area_days)
            end
          end
          # An exact name match wins outright, so "Главна" is never polluted by
          # "Нова Главна"; substring matching is only the fallback.
          days = exact.presence || fuzzy
          return nil if days.empty?

          order_days(days)
        end

        private

        # Builds area => [canonical days] from raw extracted text by walking
        # district tables and assigning each body cell to the nearest weekday
        # header column.
        def parse(text)
          result = Hash.new { |hash, key| hash[key] = [] }
          columns = nil

          text.each_line do |raw|
            line = raw.chomp

            # A "Рејон N" line closes the current table.
            if line =~ /Рејон\s*\d+/i
              columns = nil
              next
            end

            header = header_columns(line)
            if header.size >= 3
              columns = header
              next
            end

            next unless columns

            cells_for(line).each do |cell|
              column = columns.min_by { |offset, _day| (offset - cell[:offset]).abs }
              add_area(result, cell[:text], column.last)
            end
          end

          result.transform_values { |days| order_days(days) }
        end

        # Detects a weekday header row, returning [[char_offset, canonical_day]]
        # sorted left-to-right. Empty unless at least one day name is present.
        def header_columns(line)
          DAY_HEADERS.filter_map do |spelling, canonical|
            offset = line.index(spelling)
            [offset, canonical] if offset
          end.sort_by(&:first)
        end

        # Splits a body row into [{offset:, text:}] cells. Strips a leading
        # ordinal ("РБ") number (preserving column offsets), splits on runs of
        # two or more spaces, and skips structural-label-only rows.
        def cells_for(line)
          return [] if line.strip.empty?

          blanked = line.sub(/\A(\s*)(\d{1,2})\.?(\s)/) { "#{::Regexp.last_match(1)}#{" " * (::Regexp.last_match(2).length + 1)}#{::Regexp.last_match(3)}" }

          cells = []
          blanked.to_enum(:scan, /(?:\A|\s{2,})(\S[^\n]*?)(?=\s{2,}|\z)/).each do
            text = Regexp.last_match(1).strip
            cells << { offset: Regexp.last_match.begin(1), text: text } unless text.empty?
          end

          # Drop pure ordinals and subheader rows where every cell is identical
          # (e.g. "Град Град Град ...").
          cells.reject! { |cell| cell[:text].match?(/\A\d+\.?\z/) }
          return [] if cells.size > 1 && cells.map { |c| c[:text] }.uniq.size == 1

          cells
        end

        def add_area(result, text, day)
          name = clean_area(text)
          return if name.nil?

          result[name] << day unless result[name].include?(day)
        end

        # Normalizes a raw cell into an area display name, or nil if it is a
        # structural label / noise fragment.
        def clean_area(text)
          name = text.gsub(/\s+/, " ").strip
          return nil if name.length < 2
          return nil if structural_labels.include?(name)

          name
        end

        def order_days(days)
          days.uniq.sort_by { |day| WEEK_ORDER.index(day) || WEEK_ORDER.size }
        end

        # #normalize (fold) is provided by Decidim::Bih::City::Matching, shared
        # with the other City content services.

        # Downloads the schedule PDF, size-bounded, via the shared
        # Decidim::Bih::City::PdfSource. Previously this download had NO size cap;
        # it now shares Budget's MAX_PDF_BYTES guard so a wrong/compromised source
        # URL cannot stream an unbounded body into memory and a tempfile.
        def download_to_tempfile(url)
          Decidim::Bih::City::PdfSource.download_to_tempfile(
            url: url, timeout: @timeout, error_class: WasteScheduleError,
            label: "Schedule PDF", prefix: "komunalac_waste_schedule"
          )
        end
      end
    end
  end
end

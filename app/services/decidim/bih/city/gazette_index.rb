# frozen_string_literal: true

require "date"
require "nokogiri"

module Decidim
  module Bih
    module City
      # Raised when the gazette index cannot be built or parsed.
      class GazetteError < StandardError; end

      # A reusable, pure-Ruby ranked keyword search over a catalog of official
      # municipal gazette ("Службени гласник") issues / decisions. It powers a
      # concierge answer to "what did the Assembly decide about parking?" for ANY
      # municipality whose gazette is published as a year/month archive of issue
      # PDFs — the machinery here is generic and ships NO city data.
      #
      # Instantiate it with the entries for a concrete municipality (the host
      # application owns that data). Each entry is a Hash with this shape:
      #
      #   title:    String, the issue / decision title (display language)
      #   number:   String, issue designation, e.g. "07/2026"
      #   date:     String or Date, publication date ("12. маја 2026. године")
      #   url:      String, link to the source PDF (citation)
      #   summary:  String, OPTIONAL, free text describing the decisions inside,
      #             used as the main searchable body
      #
      # Matching is BOTH diacritic- and script-insensitive: queries in Serbian
      # Latin or Cyrillic match Cyrillic gazette text (a query for "parking" or
      # "паркинг" both hit a summary spelling "паркинг"), reusing the same
      # Cyrillic->Latin folding the waste-schedule parser uses.
      #
      # No network, no database: the index operates purely on the entries it is
      # given at construction time. The optional .from_index_html parser turns a
      # city portal's gazette archive page into entries.
      class GazetteIndex
        include Decidim::Bih::City::Matching

        # Default number of ranked results returned by #search and #recent.
        DEFAULT_LIMIT = 5

        # Minimum shared leading characters for a "same stem" match, so Serbian
        # declensions hit (e.g. "nabavke" vs "nabavki", "javnim" vs "javnih").
        STEM_PREFIX = 4

        # Serbian (Cyrillic and Latin) month names -> month number, for parsing
        # publication dates into something sortable. Both genitive ("маја") and
        # nominative ("мај"/"септембар") spellings appear in the source.
        MONTHS = {
          "januar" => 1, "januara" => 1,
          "februar" => 2, "februara" => 2,
          "mart" => 3, "marta" => 3,
          "april" => 4, "aprila" => 4,
          "maj" => 5, "maja" => 5,
          "jun" => 6, "juna" => 6,
          "jul" => 7, "jula" => 7,
          "avgust" => 8, "avgusta" => 8,
          "septembar" => 9, "septembra" => 9,
          "oktobar" => 10, "oktobra" => 10,
          "novembar" => 11, "novembra" => 11,
          "decembar" => 12, "decembra" => 12
        }.freeze

        # Builds an index over +entries+ (an Array of entry Hashes, see the class
        # docstring). A frozen copy is stored so callers cannot mutate the index
        # after construction. Raises GazetteError if +entries+ is not an Array.
        def initialize(entries)
          raise GazetteError, "entries must be an Array" unless entries.is_a?(Array)

          @entries = entries.each_with_index.map do |entry, position|
            normalize_entry(entry, position)
          end.freeze
        end

        # Parses a city portal gazette-archive HTML page into entries. It looks
        # for anchors whose text names a "Службени гласник ... NN/YYYY од DATE"
        # issue and links to a PDF, extracting title/number/date/url. Relative
        # PDF hrefs are absolutized against +base_url+ when given. Returns a new
        # GazetteIndex. Raises GazetteError when +html+ is blank.
        #
        # NOTE: this targets the Grad Bijeljina portal layout (a flat list of
        # issue links per year page); other portals may need their own parser.
        def self.from_index_html(html, base_url: nil)
          raise GazetteError, "html is blank" if html.nil? || html.to_s.strip.empty?

          doc = Nokogiri::HTML(html.to_s)
          entries = doc.css("a[href]").filter_map do |anchor|
            parse_anchor(anchor, base_url)
          end
          # Drop duplicate issue numbers, keeping the first occurrence.
          entries.uniq! { |entry| entry[:number] }
          new(entries)
        end

        # Matches the issue designation "NN/YYYY" (or short "N/YY") in the text.
        ISSUE_NUMBER = %r{(\d{1,3})\s*/\s*(\d{2,4})}
        # Matches the title that precedes the issue number.
        ISSUE_TITLE = %r{\A(.*?)\s*\d{1,3}\s*/}
        # Matches the publication-date phrase ("... 12. маја 2026. године").
        ISSUE_DATE = /(?:од|,)\s*(.+?године)/i
        private_constant :ISSUE_NUMBER, :ISSUE_TITLE, :ISSUE_DATE

        # Builds an entry Hash from a single <a> node, or nil if it is not a
        # gazette issue link.
        def self.parse_anchor(anchor, base_url)
          href = anchor["href"].to_s.strip
          text = anchor.text.to_s.gsub(/\s+/, " ").strip
          return nil unless href.match?(/\.pdf\z/i) && text.match?(/гласник/i)

          match = text.match(ISSUE_NUMBER) || return

          {
            title: issue_title(text),
            number: "#{match[1].rjust(2, "0")}/#{normalize_year(match[2])}",
            date: text[ISSUE_DATE, 1]&.strip,
            url: absolutize(href, base_url),
            summary: nil
          }
        end

        def self.issue_title(text)
          title = text[ISSUE_TITLE, 1].to_s.strip
          title.empty? ? "Службени гласник" : title
        end

        def self.normalize_year(raw)
          raw.length == 2 ? "20#{raw}" : raw
        end

        def self.absolutize(href, base_url)
          return href if base_url.nil? || href.match?(%r{\Ahttps?://})

          "#{base_url.to_s.sub(%r{/\z}, "")}/#{href.sub(%r{\A/}, "")}"
        end

        private_class_method :parse_anchor, :issue_title, :normalize_year, :absolutize

        # All entries, in declaration order (frozen, public-shaped hashes).
        def all
          @entries.map { |entry| public_entry(entry) }
        end

        # The +limit+ most recent issues, newest first. Ordering uses the parsed
        # publication date when available, falling back to the issue number
        # (year + sequence), then declaration order.
        def recent(limit: DEFAULT_LIMIT)
          @entries
            .sort_by { |entry| sort_key(entry) }
            .reverse
            .first(limit)
            .map { |entry| public_entry(entry) }
        end

        # Ranked entries matching a free-text query. Scoring sums query-token
        # overlaps against each entry's normalized terms (title + summary +
        # number); whole-token hits weigh more than substring hits. Returns at
        # most +limit+ entries; an empty array when nothing matches or the query
        # is blank. Ties break toward more recent issues.
        def search(query, limit: DEFAULT_LIMIT)
          tokens = tokenize(query)
          return [] if tokens.empty?

          @entries
            .map { |entry| [entry, score(entry, tokens)] }
            .select { |(_entry, points)| points.positive? }
            .sort_by { |(entry, points)| [-points, inverse_sort_key(entry)] }
            .first(limit)
            .map { |(entry, _points)| public_entry(entry) }
        end

        private

        # Builds the internal entry: the caller-facing fields plus a precomputed
        # normalized term set and a sort key.
        def normalize_entry(entry, position)
          entry = symbolize(entry)
          terms = entry_terms(entry)
          {
            title: entry[:title],
            number: entry[:number],
            date: entry[:date],
            url: entry[:url],
            summary: entry[:summary],
            terms: terms,
            position: position,
            sort_date: parse_date(entry[:date]),
            issue_key: issue_key(entry[:number])
          }.freeze
        end

        def symbolize(entry)
          raise GazetteError, "entry must be a Hash, got #{entry.class}" unless entry.is_a?(Hash)

          entry.transform_keys(&:to_sym)
        end

        def public_entry(entry)
          entry.slice(:title, :number, :date, :url, :summary)
        end

        # Normalized, deduplicated searchable terms for an entry: the tokens of
        # its title, summary and number.
        def entry_terms(entry)
          [entry[:title], entry[:summary], entry[:number]]
            .compact
            .flat_map { |field| tokenize(field) }
            .uniq
        end

        # Relevance score for an entry against the query tokens. Whole-token
        # hits weigh most; substring hits next; a shared >= STEM_PREFIX stem
        # (to absorb Serbian case endings) counts least.
        def score(entry, tokens)
          terms = entry[:terms]
          tokens.sum do |token|
            if terms.include?(token)
              3
            elsif terms.any? { |term| term.include?(token) || token.include?(term) }
              2
            elsif terms.any? { |term| shared_stem?(term, token) }
              1
            else
              0
            end
          end
        end

        # True when two tokens share at least STEM_PREFIX leading characters,
        # both being at least that long (catches inflected word forms).
        def shared_stem?(term, token)
          return false if term.length < STEM_PREFIX || token.length < STEM_PREFIX

          term[0, STEM_PREFIX] == token[0, STEM_PREFIX]
        end

        # #normalize (fold) and #tokenize are provided by
        # Decidim::Bih::City::Matching, shared with ServiceDirectory.

        # Sortable key (ascending => oldest first): primarily the parsed date,
        # then the issue (year, sequence), then declaration position.
        def sort_key(entry)
          [
            entry[:sort_date] ? entry[:sort_date].to_time.to_i : -Float::INFINITY,
            entry[:issue_key],
            entry[:position]
          ]
        end

        # Key for tie-breaking #search toward newer issues (smaller => newer).
        def inverse_sort_key(entry)
          date = entry[:sort_date]
          [date ? -date.to_time.to_i : Float::INFINITY, entry[:issue_key].map(&:-@)]
        end

        # Parses "NN/YYYY" into [year, sequence] for ordering; [0, 0] if unknown.
        def issue_key(number)
          match = number.to_s.match(%r{(\d{1,3})\s*/\s*(\d{2,4})})
          return [0, 0] unless match

          year = match[2].length == 2 ? 2000 + match[2].to_i : match[2].to_i
          [year, match[1].to_i]
        end

        # Parses a Serbian publication-date phrase into a Date, or nil.
        def parse_date(value)
          return value if value.is_a?(Date)
          return nil if value.nil?

          folded = normalize(value)
          # The first separator must be non-greedy: a greedy \D+ would eat the
          # month name down to its last letter ("12. maja" → captures "a"), so
          # MONTHS lookup failed for every real "DD. <month> YYYY." phrase.
          match = folded.match(/(\d{1,2})\D+?([a-z]+)\D+(\d{4})/)
          return nil unless match

          month = MONTHS[match[2]]
          return nil unless month

          Date.new(match[3].to_i, month, match[1].to_i)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end

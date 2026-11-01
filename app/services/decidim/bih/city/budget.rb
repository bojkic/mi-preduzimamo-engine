# frozen_string_literal: true

require "faraday"
require "tempfile"

module Decidim
  module Bih
    module City
      # Raised when a city budget cannot be fetched or parsed.
      class BudgetError < StandardError; end

      # Parses a municipal "Budžet za građane" (citizen budget) / "Odluka o
      # budžetu" document into a queryable list of {category:, amount:} line
      # items, so a concierge can answer "how much did the city budget for X?".
      #
      # This is GENERIC parsing machinery: it ships NO municipal data and knows
      # no default source URL. The caller supplies the budget text/PDF/URL (via
      # .from_text, .from_pdf, the +source_url+ constructor arg, or #fetch). The
      # host application owns the concrete municipality's captured data.
      #
      # SOURCE STRUCTURE (as published by RS/BiH municipalities): citizen-budget
      # PDFs are dominated by prose and infographics, but the reliably machine
      # readable parts are the budget-user / department / programme tables, whose
      # rows render (after pdf-reader linearisation) as:
      #
      #   <ordinal>  <optional code>  <category name>   <amount> КМ
      #
      # Two such tables are often printed SIDE BY SIDE, so a single linearised
      # line can carry TWO "name … amount" pairs. The parser therefore scans
      # every line for ALL monetary amounts and pairs each amount with the text
      # segment immediately preceding it (back to the previous amount or the line
      # start), after stripping a leading ordinal ("1.") and budget code
      # ("0005300"). This naturally handles single- and dual-column rows.
      #
      # AMOUNTS use the RS/EU convention "1.780.000,00" (dot thousands, comma
      # decimal) optionally suffixed "КМ". US-style figures from debt-annex
      # tables ("10,000,000.00") are deliberately NOT matched, to avoid noise.
      #
      # Reliability is uneven, by design of the source document: clean tabular
      # rows parse exactly, while names that wrap onto a second line yield a
      # best-effort / truncated category, and stray prose amounts can surface as
      # noise. The parser is deliberately defensive — it extracts what is
      # reliably structured, keeps the full extracted text available via
      # #raw_text, and never raises on a malformed row.
      class Budget
        include Decidim::Bih::City::Matching

        DEFAULT_TIMEOUT = 20

        # RS/EU formatted monetary amount: "1.780.000,00" optionally "1.234,50".
        # Guarded so it neither starts mid-number nor is followed by a further
        # digit (which would indicate US "10,000,000.00" formatting).
        AMOUNT = /(?<![\d.,])\d{1,3}(?:\.\d{3})*,\d{2}(?!\d)/

        # Leading noise tokens to peel off the front of a category segment, in
        # priority order: a stray currency suffix that bled over from the
        # PREVIOUS column's amount ("КМ"), a row ordinal ("1.", "15"), and a
        # budget/PJT code (a run of >= 4 digits, e.g. "0005300").
        LEADING_NOISE = [
          /\A\s*(?:КМ|KM|БАМ|BAM)\b\s*/i,
          /\A\s*\d{1,3}[.)]?\s+/,
          /\A\s*\d{4,}\s+/
        ].freeze

        # Words (any script/case) that label a stated total amount.
        TOTAL_LABEL = /укуп|ukup|total|свега|svega/i

        # Lines mentioning the budget/plan anchor the document's own fiscal year
        # (vs. comparison years referenced elsewhere in the prose).
        YEAR_ANCHOR = /буџет|план|budž|budz|plan|građan|gradan/i

        # A four-digit 20xx year token.
        YEAR = /\b(20\d{2})\b/

        # Categories longer than this are almost certainly captured prose, not a
        # real budget line, and are dropped to limit noise.
        MAX_CATEGORY_LENGTH = 70

        # Minimum length of a meaningful category name.
        MIN_CATEGORY_LENGTH = 3

        # +year+ is the parsed fiscal year (or nil); see #detect_year.
        attr_reader :source_url, :raw_text, :line_items, :year

        # +source_url+ is the caller-supplied budget URL used by #fetch; it has
        # no default because the engine ships no municipal data. +timeout+ bounds
        # the HTTP download.
        def initialize(source_url: nil, timeout: DEFAULT_TIMEOUT)
          @source_url = source_url
          @timeout = timeout
          @raw_text = nil
          @line_items = []
          @stated_total = nil
          @year = nil
        end

        def self.from_text(text)
          new.load_from_text(text)
        end

        def self.from_pdf(path)
          new.load_from_pdf(path)
        end

        def configured?
          source_url.present?
        end

        # Parses an already-extracted block of budget text. Idempotent; returns
        # self so callers can chain.
        def load_from_text(text)
          @raw_text = text.to_s
          @line_items = parse(@raw_text)
          @stated_total = detect_stated_total(@raw_text)
          @year = detect_year(@raw_text)
          self
        end

        # Extracts text from a citizen-budget PDF on disk, then parses it.
        # Requires the (already bundled) pdf-reader gem.
        def load_from_pdf(path)
          require "pdf/reader"
          text = PDF::Reader.new(path).pages.map(&:text).join("\n")
          load_from_text(text)
        rescue StandardError => e
          raise BudgetError,
                "Could not read budget PDF: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end

        # Downloads the budget PDF from +url+ (defaulting to the configured
        # +source_url+) and parses it. RAISES BudgetError when the source is
        # unreachable, returns a non-success status, or cannot be parsed — the
        # engine has no data of its own to fall back to, so the CALLER decides
        # whether to degrade (e.g. by parsing a locally held snapshot). Returns
        # self on success.
        def fetch(url: source_url)
          raise BudgetError, "No budget URL configured" if url.blank?

          path = download_to_tempfile(url)
          load_from_pdf(path)
        ensure
          path&.close!
        end

        # All parsed category names (display spelling), in document order.
        def categories
          line_items.map { |item| item[:category] }
        end

        # The document's STATED headline grand total when one is detectable,
        # otherwise the sum of the parsed line items. NOTE: a budget document's
        # headline figure may be total *revenue* while the parsed line items are
        # *expenditure* allocations — these need not be equal, and #total is not
        # "the sum of #line_items". Callers that show this to citizens should
        # know which side their source document's headline represents (the
        # Bijeljina wrapper documents this).
        def total
          @stated_total || line_items.sum { |item| item[:amount] }
        end

        # The amount budgeted for the line item best matching +query+, or nil
        # when nothing matches. Matching is diacritic- and script-insensitive
        # (Cyrillic or Latin) and fuzzy ("contains" in either direction), so
        # "socijalni rad", "Социјални", and "centar za socijalni rad" all
        # resolve. When several items match, the closest (shortest) category
        # wins.
        def amount_for(query)
          needle = normalize(query)
          return nil if needle.empty?

          best = nil
          line_items.each do |item|
            hay = normalize(item[:category])
            next unless hay.include?(needle) || needle.include?(hay)

            best = item if best.nil? || item[:category].length < best[:category].length
          end
          best && best[:amount]
        end

        private

        # Builds [{category:, amount:}] by scanning each line for all monetary
        # amounts and pairing each with the text segment preceding it.
        def parse(text)
          items = []
          text.each_line do |raw|
            line = raw.chomp
            cursor = 0
            line.to_enum(:scan, AMOUNT).each do
              match = Regexp.last_match
              segment = line[cursor...match.begin(0)]
              cursor = match.end(0)
              category = clean_category(segment)
              next if category.nil?
              next if total_row?(category)

              items << { category: category, amount: parse_amount(match[0]) }
            end
          end
          items
        end

        # Normalizes a raw segment into a category name, or nil when it is noise
        # (too short, too long, or label-only).
        def clean_category(segment)
          name = segment.to_s.gsub(/\s+/, " ").strip
          # Peel leading noise tokens until the string stabilises (a row can be
          # prefixed by "КМ 1. 0009200 …").
          loop do
            before = name
            LEADING_NOISE.each { |pattern| name = name.sub(pattern, "") }
            break if name == before
          end
          name = name.strip
          return nil if name.length < MIN_CATEGORY_LENGTH
          return nil if name.length > MAX_CATEGORY_LENGTH
          return nil unless name.match?(/\p{L}{3}/)

          name
        end

        # A row introduced by a total keyword ("УКУПНО", "УКУПНО корисници ...")
        # is a structural subtotal/total, not a real budget category, so it is
        # dropped from the line items. It still feeds #total independently via
        # #detect_stated_total, which rescans the raw text.
        def total_row?(name)
          name.match?(TOTAL_LABEL)
        end

        # Converts "1.780.000,00" -> 1_780_000 (Integer when whole) or a Float
        # when there are non-zero cents ("1.234,50" -> 1234.5).
        def parse_amount(token)
          digits = token.tr(".", "").tr(",", ".")
          value = digits.to_f
          value == value.to_i ? value.to_i : value
        end

        # The document's stated grand total: the largest amount appearing on a
        # line that carries a total-label keyword. nil when none is present.
        def detect_stated_total(text)
          totals = []
          text.each_line do |line|
            next unless line.match?(TOTAL_LABEL)

            line.scan(AMOUNT) { |amount| totals << parse_amount(amount) }
          end
          totals.max
        end

        # The document's own fiscal year. Years are far more reliable than
        # amounts here, but citizen budgets also cite comparison years (e.g.
        # "... у односу на 2021. годину"), so we prefer the year most frequently
        # named ALONGSIDE a budget/plan keyword, falling back to the overall most
        # frequent year, tie-broken by the latest. nil when no year appears.
        def detect_year(text)
          anchored = Hash.new(0)
          overall = Hash.new(0)
          text.each_line do |line|
            years = line.scan(YEAR).flatten.map(&:to_i)
            years.each do |y|
              overall[y] += 1
              anchored[y] += 1 if line.match?(YEAR_ANCHOR)
            end
          end
          tally = anchored.empty? ? overall : anchored
          return nil if tally.empty?

          tally.max_by { |year, count| [count, year] }.first
        end

        # #normalize (fold) is provided by Decidim::Bih::City::Matching, shared
        # with the other City content services.

        # Downloads the budget PDF, size-bounded, via the shared
        # Decidim::Bih::City::PdfSource (the MAX_PDF_BYTES cap now lives there and
        # is shared with WasteSchedule).
        def download_to_tempfile(url)
          Decidim::Bih::City::PdfSource.download_to_tempfile(
            url: url, timeout: @timeout, error_class: BudgetError,
            label: "Budget PDF", prefix: "city_budget"
          )
        end
      end
    end
  end
end

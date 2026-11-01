# frozen_string_literal: true

module Decidim
  module Bih
    module City
      # A reusable, pure-Ruby ranked search/lookup over a directory of civic
      # services. It powers a "how do I / where do I / who do I contact"
      # concierge — the "find out what I need" content layer — for ANY
      # municipality: the machinery here is generic and ships NO city data.
      #
      # Instantiate it with the entries for a concrete municipality (the host
      # application owns that data). Each entry is a Hash with this shape:
      #
      #   key:        Symbol, stable identifier (also used by #find)
      #   title:      short human label (display language)
      #   keywords:   Array<String>, search terms (incl. diacritic/common forms)
      #   answer:     concise, citizen-friendly answer text
      #   source_url: String, citation for the underlying official source
      #
      # Matching is BOTH diacritic- and script-insensitive: a query for
      # "maticar" matches an entry keyworded "matičar", and a Cyrillic query
      # ("вода") matches a Latin keyword ("voda"), reusing the shared
      # Decidim::Bih::Text.fold folding the other content services use.
      #
      # No network, no database: the directory operates purely on the entries it
      # is given at construction time.
      class ServiceDirectory
        include Decidim::Bih::City::Matching

        # Default number of ranked results returned by #search.
        DEFAULT_LIMIT = 3
        STOPWORDS = %w(
          a ako ali bez bi bih bilo da do gde gdje hoce hocu ima imam ima li
          iz ja je jer jos kad kada kako kod koja koje koji kome kuda li me mi
          moze mozes mogu moje moj moja na neki neko nesto nije od oko oni ono
          pa po pod reci sta sto sve ta taj to treba tu u uradi uradim uradis
          za zasto
        ).freeze
        MIN_FUZZY_TOKEN_LENGTH = 4
        # What one query token is worth against an entry: naming one of its
        # terms outright, or merely overlapping one.
        EXACT_POINTS = 2
        FUZZY_POINTS = 1
        # A token that is nothing but digits. Kept as its own concept because
        # such a token scores like any other word and means far less.
        DIGITS_ONLY = /\A\d+\z/

        # Builds a directory over +entries+ (an Array of entry Hashes, see the
        # class docstring). A frozen, deep copy is stored so callers cannot
        # mutate the directory after construction.
        def initialize(entries)
          @entries = entries.map { |entry| deep_freeze_entry(entry) }.freeze
        end

        # All entries, in declaration order (frozen).
        def all
          @entries
        end

        # The entry with the given key (Symbol or String), or nil.
        def find(key)
          @entries.find { |entry| entry[:key] == key.to_sym }
        end

        # Ranked entries matching a free-text query. Scoring is the sum of
        # keyword/title token overlaps against the normalized query, so the most
        # relevant service comes first. Returns at most +limit+ entries; an
        # empty array when nothing matches or the query is blank.
        def search(query, limit: DEFAULT_LIMIT)
          tokens = search_tokens(query)
          return [] if tokens.empty?

          @entries
            .map { |entry| [entry, score(entry, tokens)] }
            .select { |(_entry, points)| points.positive? }
            .sort_by { |(entry, points)| [-points, @entries.index(entry)] }
            .first(limit)
            .map(&:first)
        end

        private

        # Returns a frozen copy of +entry+ whose nested :keywords array (and its
        # strings) are frozen too. A shallow entry.dup.freeze leaves the shared
        # :keywords array mutable, so a caller could mutate directory state
        # through a returned entry; this deep-freeze upholds the safety claim.
        def deep_freeze_entry(entry)
          copy = entry.dup
          if copy[:keywords].is_a?(Array)
            copy[:keywords] = copy[:keywords].map { |kw| kw.frozen? ? kw : kw.dup.freeze }.freeze
          end
          copy.freeze
        end

        # #normalize (fold) and #tokenize are provided by
        # Decidim::Bih::City::Matching, shared with GazetteIndex.

        def search_tokens(query)
          tokenize(query).reject { |token| STOPWORDS.include?(token) }
        end

        # Relevance score for an entry against the query tokens. Each query token
        # that appears in (or as a substring of) the entry's normalized terms
        # adds to the score; whole-keyword hits weigh more than substring hits.
        #
        # An entry nobody NAMED scores nothing, however many weak hits it
        # collected: see #named?.
        def score(entry, tokens)
          terms = entry_terms(entry)
          hits = tokens.filter_map do |token|
            points = points_for(terms, token)
            [token, points] if points.positive?
          end
          return 0 unless named?(hits)

          hits.sum { |(_token, points)| points }
        end

        # Two kinds of hit cannot, alone, decide that a query is ABOUT an
        # entry; both were measured routing real questions to the wrong
        # service on 14.09.2026:
        #
        #   * a bare number. "48" is a keyword and a title word of the Sistem
        #     48 entry, so "Kad oni stižu: odmah, nakon 24 ili nakon 48 sati?"
        #     scored a clean whole-term hit and was answered with the city's
        #     complaint-reporting card. A number identifies nothing on its own
        #     — it can only confirm a service some word already named.
        #   * a lone substring overlap. "uslov" in "Da li je potvrda dolaska
        #     uslov za ulaz ili samo molba?" overlaps "uslovi" in the building
        #     permits entry's "lokacijski uslovi", and that single fuzzy point
        #     was the whole match, so an invitation question was answered with
        #     the Odsjek za građevinske i upotrebne dozvole.
        #
        # Both remain fully reachable, because a real question about either
        # names it: "Šta je Sistem 48?" still scores on "sistem", and "Koji su
        # lokacijski uslovi za gradnju?" on "lokacijski" and "uslovi".
        def named?(hits)
          hits.any? { |(token, points)| points == EXACT_POINTS && !DIGITS_ONLY.match?(token) }
        end

        def points_for(terms, token)
          return EXACT_POINTS if terms.include?(token)
          return FUZZY_POINTS if terms.any? { |term| fuzzy_match?(term, token) }

          0
        end

        def fuzzy_match?(term, token)
          return false if term.length < MIN_FUZZY_TOKEN_LENGTH || token.length < MIN_FUZZY_TOKEN_LENGTH

          term.include?(token) || token.include?(term)
        end

        # Normalized, deduplicated set of searchable terms for an entry:
        # its keywords plus the individual words of its title.
        def entry_terms(entry)
          (entry[:keywords] + entry[:title].split(/\s+/))
            .flat_map { |word| tokenize(word) }
            .uniq
        end
      end
    end
  end
end

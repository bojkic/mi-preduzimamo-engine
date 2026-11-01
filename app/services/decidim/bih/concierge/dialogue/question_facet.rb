# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # WHAT is being asked about a topic, as opposed to WHICH topic it is.
        #
        # The dialogue carries an action, a topic and a flat entity bag. None of
        # those says whether the citizen wants a collection day, a price, a
        # phone number, an operator's name, opening hours or simply a shorter
        # answer — so a fee question and a recycling-yard question used to be
        # answered by the collection-day reader, and a contact question was
        # answered with "which neighbourhood?".
        #
        # A facet is a closed token derived deterministically from the citizen's
        # own current words. It is never a model output, never stored in state,
        # and never a permission: it only decides which reviewed reader a turn
        # should reach. Returning +nil+ means "no facet recognised", which keeps
        # the pre-facet routing exactly as it was.
        #
        # Both sides of the read port use this one rule: the engine to decide
        # whether a service question still needs a place, the host to decide
        # which source family answers it.
        module QuestionFacet
          FACETS = %w(contact website operator hours fee coverage status location schedule).freeze
          # Facets a reviewed contact card answers. None of them needs a
          # neighbourhood, a day or a date first.
          DIRECTORY = %w(contact website operator hours).freeze
          MAX_LENGTH = 400

          CONTACT = /\b(?:telefon\w*|kontakt\w*|mobitel\w*|mejl\w*|e[ ]mail|imejl\w*|pozovem|pozvati|javim[ ]se|phone|contact|e[ ]mail[ ]address)\b/
          WEBSITE = /\b(?:stranic\w*|sajt\w*|web|website|site|internet[ ]stranic\w*|link)\b/
          OPERATOR = /\b(?:ko[ ]upravlja|ko[ ]vodi|ko[ ]odrzava|ko[ ]je[ ]nadlezan|ko[ ]je[ ]zaduzen|nadlezn\w*|
                        koje[ ]preduzece|koja[ ]sluzba|ko[ ]radi[ ]na|who[ ]runs|who[ ]manages|who[ ]is[ ]responsible)\b/x
          HOURS = /\b(?:radno[ ]vrijeme|radno[ ]vreme|radn[oi][ ]vremen\w*|rade[ ]li|radi[ ]li|da[ ]li[ ]rade|da[ ]li[ ]radi|
                     subotom|nedjeljom|nedeljom|vikendom|salter\w*|working[ ]hours|opening[ ]hours|open[ ]on)\b/x
          FEE = /\b(?:kosta|kostaju|kostati|cijen[aeiu]\w*|cen[aeu]|cjenovnik\w*|cenovnik\w*|tarif\w*|naknad\w*|taks[aeiu]\w*|
                   naplac\w*|racun\w*|mjesecno|mesecno|price|prices|cost|costs|fee|fees|how[ ]much)\b/x
          COVERAGE = /\b(?:tice|tice[ ]li|obuhvat\w*|odnosi[ ]se|znaci[ ]li[ ]to|da[ ]li[ ]to[ ]znaci|pokriv\w*|
                        vazi[ ]li[ ]za|does[ ]that[ ]mean|affect|affects|apply[ ]to)\b/x
          STATUS = /\b(?:prekid\w*|kvar\w*|nestal\w*|nestank\w*|iskljucenj\w*|obustav\w*|redukcij\w*|trenutno|aktuel\w*|
                      outage\w*|currently|current|right[ ]now|live|status|working|restored)\b/x
          LOCATION = /\b(?:gdje[ ]je|gde[ ]je|gdje[ ]su|gde[ ]su|gdje[ ]mogu[ ]naci|najblizi|najbliza|najblize|najblizeg|
                        lokacij\w*|where[ ]is|where[ ]are|nearest)\b/x
          SCHEDULE = /\b(?:kad|kada|koji[ ]dan|kojim[ ]danom|kojeg[ ]dana|raspored\w*|odvoz\w*|odvozi|odvoze|kupi[ ]smece|
                        termin\w*|datum\w*|rok|roka|roku|rokovi\w*|sat|sata|satu|vrijeme|vreme|
                        schedule|what[ ]day|which[ ]day|when|deadline\w*|date)\b/x

          # First match wins; the order is from the most specific request to the
          # most general, so "koliko košta odvoz" is a fee question and not a
          # collection-day one.
          ORDERED = [
            ["contact", CONTACT], ["website", WEBSITE], ["operator", OPERATOR], ["hours", HOURS],
            ["fee", FEE], ["coverage", COVERAGE], ["status", STATUS], ["location", LOCATION], ["schedule", SCHEDULE]
          ].freeze

          # A request that is NEGATED is not that request: "ne želim službenu
          # stranicu" must not be answered with the official page.
          NEGATION = /\b(?:ne|nije|nisu|nemoj\w*|not|no|don[ ]t|without|bez)\b/

          module_function

          # +text+ is the citizen's own current words (raw, not folded).
          def call(text)
            return unless text.is_a?(String)

            value = text.strip
            return if value.empty? || value.length > MAX_LENGTH

            folded = Text.fold(value)
            return if folded.empty?

            ORDERED.each { |name, pattern| return name if folded.match?(pattern) }
            nil
          end

          # A reviewed directory card answers this question; no place, day or
          # date may be demanded before it is read.
          #
          # Two refusals, both deliberate. A NEGATED request is not that
          # request. And a sentence that also asks about the LIVE state of the
          # service ("what is the official website and is the water working?")
          # still needs the place the live half depends on, so it keeps its old
          # path — the same rule ServiceQuestion applies to mixed clauses.
          def directory?(text)
            return false unless DIRECTORY.include?(call(text))

            folded = Text.fold(text.to_s)
            !folded.match?(NEGATION) && !folded.match?(STATUS) && !folded.match?(COVERAGE)
          end
        end
      end
    end
  end
end

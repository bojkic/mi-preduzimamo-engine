# frozen_string_literal: true

require_relative "contracts"
require_relative "state_store"
require_relative "transport_question_route"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Supply one missing journey field or change its time window without
        # asking the model to reconstruct the other endpoints. Stop identity
        # and service availability remain the host reader's responsibility.
        module TransportFollowUpQuestion
          PLACE_PHRASE = /\A(?:a\s+)?(?:(?:krecem|polazim)\s+)?(?:od|iz|sa|s|from|do|to)\s+(?<place>[\p{L}\d-]+(?:\s+[\p{L}\d-]+){0,3})\z/
          CLAUSE_WORD = /\b(?:ko|koga|kome|koj\w*|kak\w*|koliko|kada|kad|sta|sto|mene|tebe|njega|nje|se|je|ne|znam|sve|trazi|traje|when|where|what|which|now)\b/
          DAY = /\A(?:a\s+)?(?:u\s+|za\s+)?
                 (?:subot\w*|nedjel\w*|nedelj\w*|ponedjel\w*|ponedel\w*|utor\w*|srijed\w*|
                    sred[au]|cetvrt\w*|petak|sutra|preksutra|danas|saturday|sunday|tomorrow)
                 (?:\s+(?:nakon|poslije|posle|u|oko)\s+\d{1,2}(?:[: ]\d{2})?)?\z/x
          TIME = /\A(?:a\s+)?(?:nakon|poslije|posle|u|oko|after|at)\s+\d{1,2}(?:[: ]\d{2})?\z/
          CLOCK_CORRECTION = /\A(?:ne[ ](?:u[ ])?\d{1,2}(?:[: ]\d{2})?[ ])?
            (?:(?:treba[ ]mi|zelim|hocu)[ ])?(?:prvi[ ]|prvi[ ]polazak[ ])?
            (?:nakon|poslije|posle|after)[ ]\d{1,2}(?:[: ]\d{2})?(?:[ ](?:casova|sati|h))?\z/x
          DAY_CORRECTION = /\A(?:pitao[ ]sam|pitala[ ]sam|pitam|mislim)[ ]za[ ]
            (?:subot\w*|nedjel\w*|nedelj\w*|sutra|danas)(?:[ ]ne[ ]za[ ](?:danas|sutra))?\z/x
          TRANSFER = /\A(?:a\s+)?(?:(?:da\s+li|je\s+li)\s+)?
                      (?:treba(?:m)?\s+(?:li\s+)?(?:da\s+)?(?:presjednem|presednem|presjedanje|presedanje)|
                         ima\s+li\s+presjedanja|moze\s+i\s+presjedanje)\z/x

          FACET_OTHER_TASK = /\b(?:nalog|registr\w*|lozink\w*|bodov\w*|poen\w*|prijav\w*|objav\w*|donacij\w*)\b/
          FACET_QUESTION = /\A(?:(?:korisno|hvala|dobro|a|i|pa)[ ])*(?:koliko|koliki|gdje|gde|odakle|koje|koji|kako|sta|da[ ]li|je[ ]li|razlikuje|razlikuju|uporedi|usporedi|odvoji|objasni)\b/
          NON_PLACE = /\A(?:smjer\w*|smer\w*|prelazak|prelaska|presjedanje|presjedanja|prelaz|drugog[ ]stajalista|
            medjugradskog[ ]reda|gradskog[ ]reda|red[ ]voznje)\z|\b(?:koliko|vremena|ostaje|moze[ ]veza)\b/x

          module_function

          def place_phrase?(query)
            PLACE_PHRASE.match?(query) && !CLAUSE_WORD.match?(query)
          end

          def eligible_text?(text, state)
            !state["draft"] && text.is_a?(String) && text.length.between?(1, 160) && !StateStore.sensitive_text?(text)
          end

          def capability_question?(query)
            return false unless /\A(?:a\s+)?(?:mozes\s+li|mozete\s+li|da\s+li|jesu\s+li|je\s+li|kasni\s+li|can\s+you|is|are|does)\b/.match?(query)
            return false if /\b(?:gdje|gde|where|kada|when|koliko|ne)\b/.match?(query)

            return false unless /\b(?:autobus\w*|stajal\w*|bus|buses|vehicle|stop)\b/.match?(query)
            return false if /\b(?:prijav\w*|nego|ali|instead|report)\b/.match?(query)

            /\b(?:uzivo|kasni|kasnjenje|kolic\w*|prilagodjen\w*|pristupac\w*|live|delay\w*|wheelchair|accessible)\b/.match?(query)
          end

          # A clarification of the destination is not a newly supplied origin.
          # "Mislim na školu u Janji" qualifies the previously named school;
          # the host still resolves that place against the reviewed registry.
          def destination_refinement?(text, state:)
            return false unless state.values_at("active_task", "topic") == %w(ask_information transport)
            return false unless eligible_text?(text, state)

            query = Text.fold(text)
            return false if /\b(?:i|ili|ali|pa|onda|nego|prijav\w*|registr\w*|objav\w*|posalj\w*|obris\w*)\b/.match?(query)
            return false if CLAUSE_WORD.match?(query)

            direct = /\A(?:a[ ])?do[ ](?<place>[a-z0-9][a-z0-9 ()-]{1,100})\z/.match(query)
            if direct && !CLAUSE_WORD.match?(query) && !/\b(?:od|iz|sa|preko|pa|onda|nego|do)\b/.match?(direct[:place])
              return true
            end

            match = /\A(?:mislim[ ]na|odrediste[ ]je)[ ](?<place>[a-z0-9][a-z0-9 ()-]{1,100})\z/.match(query)
            return false unless match

            destination = state.fetch("entities", {})["area_query"].to_s
            return false if destination.empty?

            terms = destination_terms(destination)
            return false if terms.empty? || (terms & destination_terms(match[:place])).empty?

            # If the same landmark also names the retained origin, the wording
            # cannot distinguish those roles. Keep ordinary ambiguity handling.
            origin_terms = destination_terms(state.fetch("entities", {})["stop"].to_s)
            (terms & origin_terms & destination_terms(match[:place])).empty?
          end

          def destination_terms(text)
            Text.fold(text).split.select { |term| term.length >= 4 }.map { |term| term[0, 4] }.uniq
          end

          def facet_follow_up?(text)
            query = Text.fold(text.to_s)
            return false unless query.length.between?(4, 160)
            return false if FACET_OTHER_TASK.match?(query) || /\A(?:ne[ ]pitam|ne[ ]zanima|nemoj[ ]odgovarati)\b/.match?(query)
            return true if /\A(?:ne[ ]mijenjaj|ne[ ]menjaj|nemoj[ ]mijenjati|zadrzi|ostavi)[ ](?:krajnje[ ])?odrediste\b/.match?(query)
            calendar_reference = /\A(?:mislim|pitam|racunaj)\b/.match?(query) && /\b(?:sutra|danas|preksutra)\b/.match?(query) &&
                                 /\b(?:razgovor\w*|danasnji[ ]datum|ovaj[ ]datum)\b/.match?(query)
            return true if calendar_reference
            return false unless FACET_QUESTION.match?(query)

            transfer = /\b(?:presje\w*|presed\w*|prelazak|cekam|cekanj\w*|ulazni|izlazni)\b/.match?(query)
            boarding = /\b(?:ulazim|ukrcavam|ukrcati|ulazak)\b/.match?(query)
            direction = /\b(?:smjer\w*|smer\w*|pravac|pravcu)\b/.match?(query) &&
                        /\b(?:razlik\w*|drugi|drugog|drugom|isti|ista|istog|uporedi|usporedi)\b/.match?(query)
            scope = /\bgradsk\w*\b/.match?(query) && /\bmedjugradsk\w*\b/.match?(query)
            service = /\bskolsk\w*\b/.match?(query) && /\b(?:redovn\w*|polas\w*|polazak|raspust\w*)\b/.match?(query)
            transfer || boarding || direction || scope || service
          end

          # The transfer summary renders location and wait together. Other
          # transport facets (calendar, direction, source scope) are independent
          # questions and must remain resumable even inside one transport task.
          def complementary_transfer_questions?(questions)
            return false unless questions.length == 2

            kinds = questions.map do |part|
              next unless facet_follow_up?(part)

              query = Text.fold(part)
              next if /\b(?:skolsk\w*|redovn\w*|kalendar\w*|smjer\w*|smer\w*|medjugradsk\w*)\b/.match?(query)
              if /\A(?:gdje|gde|odakle)\b/.match?(query) && /\b(?:presje\w*|presed\w*|ulazim|izlazim)\b/.match?(query)
                :location
              elsif /\A(?:koliko|koliki)\b/.match?(query) && /\b(?:cekam|cekanj\w*|razmak)\b/.match?(query)
                :wait
              end
            end
            kinds.sort_by(&:to_s) == [:location, :wait]
          end

          def place_candidate?(value)
            !NON_PLACE.match?(Text.fold(value.to_s))
          end

          def refinement?(query)
            facet_follow_up?(query) || capability_question?(query) || place_phrase?(query) || DAY.match?(query) || TIME.match?(query) || CLOCK_CORRECTION.match?(query) || DAY_CORRECTION.match?(query) || TRANSFER.match?(query) ||
              /\A(?:a\s+)?sa\s+presjedanjem\s+do\s+/.match?(query)
          end

          # A supplied starting landmark refines a nearest-stop question; it
          # does not create a journey with a missing destination. Recompute the
          # bounded query on the server so model paraphrases cannot supply this
          # retained-topic exception. Geography remains the host's responsibility.
          def nearest_location_query(text, state:)
            return unless state.values_at("active_task", "topic") == %w(ask_information transport)
            return unless eligible_text?(text, state) && text.length <= 130
            return unless TransportQuestionRoute::NEAREST.match?(Text.fold(state.dig("entities", "query").to_s))
            return unless %w(stop area_query).include?(state["pending_slot"])
            return if state.dig("entities", "area_query")

            query = Text.fold(text)
            return if query.match?(/\b(?:do|za|prema|ka|sutra|danas|kada|kad|kako|gdje|gde|koji|koliko|i|ili|ali|pa|onda|ne|prijav\w*|posalj\w*|registr\w*|nalog|obris\w*)\b/)
            return unless query.match?(/\A(?:(?:nalazim\s+se|ja\s+sam|trenutno\s+sam|ovdje\s+sam|ovde\s+sam|sam)\s+)?(?:kod|pored|blizu)\s+[a-z0-9]+(?:[ -][a-z0-9]+){0,8}\z/)

            "Najbliže stajalište. #{text.strip}"
          end

          def calendar_follow_up_kind(text)
            query = Text.fold(text.to_s)
            return unless query.length.between?(4, 130)

            if query.match?(/\A(?:treba\s+li\s+(?:ti\s+)?|da\s+li\s+(?:ti\s+)?treba\s+|je\s+li\s+potreban\s+)(?:(?:tacan|konkretan)\s+)?datum(?:\s+putovanja)?\z/)
              return :date_needed
            end
            if query.match?(/\A(?:da\s+li\s+)?(?:za\s+(?:taj|isti)\s+(?:datum|dan)\s+)?(?:imas\s+(?:li\s+)?|mozes\s+li\s+)(?:potvrdjen\w*|potvrditi|provjeren\w*)\s+(?:uslugu|polaske|polazak|voznju)(?:\s+za\s+(?:taj|isti)\s+(?:datum|dan))?\z/)
              return :confirmation
            end
            nil
          end

          def calendar_continuation_query(text, state:)
            return unless state.values_at("active_task", "topic") == %w(ask_information transport)
            return unless eligible_text?(text, state) && calendar_follow_up_kind(text)
            entities = state.fetch("entities", {})
            return if %w(stop area_query via_stop).any? { |key| !entities[key].to_s.empty? }

            previous = entities["query"].to_s
            query = Text.fold(previous)
            return unless previous.length.between?(1, 160) && !StateStore.sensitive_text?(previous)
            return if query.match?(/\b(?:iz|od|sa|from)\b.+\b(?:do|za|to)\b/)
            return if query.match?(/\b(?:do|prema|ka|to)\s+[a-z]/)
            calendar = /\b(?:raspored|red\s+voznje|kalendar|polasc\w*|polazak\w*|linij\w*|autobus\w*|[gp]\s*\d+)\b/.match?(query)
            day = /\b(?:subot\w*|nedjel\w*|nedelj\w*|praznik\w*|raspust\w*|datum\w*|kalendar\w*|20\d{2})\b/.match?(query)
            return unless calendar && day

            previous
          end

          def service_kind_question?(text)
            query = Text.fold(text.to_s)
            facet_follow_up?(text) && /\bskolsk\w*\b/.match?(query) && /\bredovn\w*\b/.match?(query)
          end

          def call(text, state:)
            return unless state.values_at("active_task", "topic") == %w(ask_information transport)
            return unless eligible_text?(text, state)

            if (retained_query = nearest_location_query(text, state:) || calendar_continuation_query(text, state:))
              return { action: "ask_information", topic: "transport", operation: "continue",
                       entities: { "query" => retained_query }, needs_clarification: false, secondary: nil,
                       locale: state.fetch("locale") }
            end
            query = Text.fold(text)
            return if /\b(?:prijav\w*|registr\w*|nalog|lozink\w*|objav\w*|radi|pocinje|answer|reply|speak)\b/.match?(query)
            return unless refinement?(query) || destination_refinement?(text, state:) || TransportQuestionRoute.conceptual_request(text, state:)

            { action: "ask_information", topic: "transport", operation: "continue",
              entities: { "query" => text }, needs_clarification: false, secondary: nil,
              locale: state.fetch("locale") }
          end
        end
      end
    end
  end
end

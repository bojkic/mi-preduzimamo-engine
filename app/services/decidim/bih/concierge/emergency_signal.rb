# frozen_string_literal: true

require_relative "../text"

module Decidim
  module Bih
    module Concierge
      # Recognize immediate physical danger, not a topic such as flood plans
      # or an old damaged container. No model, effects or emergency-number data.
      #
      # == What changed and why
      #
      # +dangerous_statement?+ used to require BOTH an object from a fixed list
      # AND a fire VERB, and the verb list held no noun at all: "gori kontejner"
      # was recognised, "požar u kontejneru" was not, and the noun form fell
      # through to the model, which answered it only sometimes. Measured on
      # production, 14.09.2026, eight fresh sessions per arm: the verb form got
      # the emergency card 8/8, the noun form 6/8.
      #
      # So: an unambiguous danger NOUN ("požar", "vatra", "u plamenu") now needs
      # no object, and the fire VERB no longer needs one either — an object list
      # can never contain every roof, garage or haystack. What the verb needs
      # instead is the absence of a figurative reading ("gori mi rok", "gori
      # ulična rasvjeta"), which is a closed set in a way that objects are not.
      #
      # == What it still refuses to call an emergency
      #
      # Negation, the past, the hypothetical, a drill, a plan or a topic
      # ("zaštita od požara", "osiguranje od požara"), a river-level question
      # and a plain "is there any" information request. Every guard is
      # CLAUSE-LOCAL: "kontejner ne gori, ali voda ulazi u kuću" is still an
      # emergency, because only the first clause is negated.
      #
      # == Beyond yes/no
      #
      # +assess+ returns WHICH danger is present, so the reply can name the
      # relevant service instead of reading out a directory. +call+ is kept as
      # the boolean predicate the Responder's red-zone gate already uses, and is
      # now defined in terms of +assess+, so the two can never disagree.
      module EmergencySignal
        # The typed answer to "what is happening". +kind+ is the danger the
        # reply leads with; +also+ is a second service the same message asked
        # for (gas leak AND an unconscious neighbour), or nil.
        Assessment = Data.define(:kind, :also) do
          def kinds = [kind, also].compact
        end

        # Every kind this module can report, in the order it prefers when one
        # message contains several. A casualty outranks the hazard that caused
        # it only for the SECOND line: the hazard is what stops more casualties,
        # so it leads, and the casualty is named right after it.
        KINDS = %w(fire gas flood trapped medical).freeze
        MAX_LENGTH = 2000

        # --- what is happening -------------------------------------------
        # Every pattern below runs on FOLDED text (lowercase ASCII Latin, so
        # Cyrillic and diacritics are already normalised). The /x patterns spell
        # a literal space as \s, because /x drops real spaces.
        #
        # Nouns are unambiguous on their own. "vatrogasci" is deliberately NOT
        # here: asking for the fire brigade's number is a contact request.
        FIRE_NOUN = /\b(?:pozar\w*|vatra|vatre|vatru|vatrom|plamen\w*|fire|flames?)\b/
        # "gori" carries the fire on its own; "gore" is also the ordinary word
        # for "up there", so it keeps the object it always needed.
        FIRE_VERB = /\b(?:gori|plamti|izbio\s(?:je\s)?pozar|(?:zapalio|zapalila|zapalilo)\sse|
                       se\s(?:zapalio|zapalila|zapalilo)|zapaljen\w*|burning|on\sfire|caught\sfire)\b/x
        FIRE_VERB_WITH_OBJECT = /\b(?:gore|gorimo)\b/
        FIRE_OBJECT = /\b(?:kontejner\w*|kant\w*|kuc\w*|zgrad\w*|stan\w*|vozil\w*|auto|ograda|suma|
                         krov\w*|garaz\w*|container|bin|house|building|car)\b/x
        # Smoke alone is a chimney; spreading or thick smoke is not.
        SMOKE = /\b(?:siri\sse\sdim|dim\sse\ssiri|gust\w*\sdim\w*|puno\sdima|zadimljen\w*|
                   thick\ssmoke|smoke\sis\sspreading)\b/x
        # A figurative or household "gori" — the whole reason the verb used to
        # need an object. Checked only for the verb, never for the nouns.
        FIRE_FIGURATIVE = /\b(?:gori\w*\s(?:mi\s|nam\s|ti\s|vam\s)?(?:u\s)?
                              (?:grlu|stomak\w*|zeludac|zelucu|dusa|dusi|rok\w*|termin\w*|posao|
                                 pod\snogama|od\szelje|od\snestrpljenja)|
                            rasvjet\w*|rasvet\w*|svjetl\w*|svetl\w*|sijalic\w*|lamp\w*|led|ekran|monitor|indikator\w*|
                            gori\w*\spitanj\w*|burning\squestion|sve\sgori\si\sgori|(?:je|su)\sgori\w*\s(?:nego|od))\b/x
        GAS = /\b(?:curi\s(?:plin|gas|gasa|plina)|(?:plin|gas)\scuri|curenj\w*\s(?:plina|gasa)|
                 (?:smrdi|miris\w*|osjeca\sse|oseca\sse|osjecam|osecam)\sna\s(?:plin|gas|gasa|plina|hemikalij\w*)|
                 miris\s(?:plina|gasa)|propan|butan|hemijsk\w*|hemikalij\w*|otrovn\w*|chemical\w*|toxic|
                 gas\sleak|smells?\s(?:of\s)?gas|eksplozij\w*|eksplodir\w*|explosion|exploded)\b/x
        MEDICAL = /\b(?:ne\sreaguje|ne\sodgovara\sna\spoziv|ne\sdise|ne\sdisu|bez\ssvijesti|bez\ssvesti|
                     onesvijesti\w*|onesvesti\w*|(?:se\s)?srusi[ol]\w*|kolabir\w*|infarkt|mozdani\sudar|
                     jako\skrvari|krvari\sna|povrijedjen\w*|povredjen\w*|unconscious|not\sbreathing|
                     collapsed|passed\sout|is\sbleeding|heart\sattack|stroke)\b/x
        # Water that is coming in, or coming up, where people live.
        FLOOD = /\b(?:voda\s(?:(?:mi|nam)\s)?(?:brzo\s)?(?:nadolazi|raste|nadire)|nivo\svode\s(?:brzo\s)?raste|
                   voda\b[^.!?]{0,40}?\b(?:ulazi|ulaze|usla|prodire|prodrla|probila|probija|plavi|poplavil\w*)\b[^.!?]{0,25}?
                     \b(?:kuc\w*|stan\w*|podrum\w*|objek\w*|zgrad\w*|dvorist\w*|prostorij\w*|naselj\w*)|
                   bujica\s(?:nadolazi|nadire|nosi)|(?:floodwater|flood\swater|water)\s(?:is\s)?(?:rapidly\s)?rising|
                   water\s(?:is\s)?entering\s(?:my\s|the\s)?(?:house|home|basement))\b/x
        PERSON = /\b(?:covjek|covek|osob\w*|dijete|dete|djete|djeca|deca|neko|ljudi|komsij\w*|sam|smo|
                    someone|somebody|person|people|child|children|man|woman|i\sam|i\sm|we\sare|we\sre)\b/x
        TRAPPED = /\b(?:zarobljen\w*|zatrpan\w*|zaglavljen\w*|zaglavi[ol]\w*|trapped|buried|stuck)\b/
        # A structure that came down is a rescue, not an ambulance call.
        COLLAPSE = /\b(?:(?:zgrad\w*|kuc\w*|krov\w*|zid\w*|plafon\w*|balkon\w*|skel\w*|terasa)
                        [^.!?]{0,20}?(?:se\s)?(?:srusi\w*|urusi\w*)|
                      (?:srusi\w*|urusi\w*)[^.!?]{0,20}?\b(?:zgrad\w*|kuc\w*|krov\w*|zid\w*|plafon\w*|skel\w*)|
                      building\scollapsed|roof\scollapsed|wall\scollapsed)\b/x
        NO_WAY_OUT = /\bne\smogu\s(?:da\s)?(?:izaci|izadjem|izidjem|van)\b[^.!?]{0,12}?
                       \b(?:lifta|liftu|auta|automobila|kuce|zgrade|stana|podruma|sobe)\b/x

        # --- what is NOT happening ----------------------------------------
        DENIAL = /\b(?:ne\s(?:gori|gore|raste|nadolazi|nadire|ulazi|prodire|plavi|curi|krvari)|
                    nije\s(?:zarobljen\w*|zatrpan\w*|zaglavljen\w*|zapaljen\w*|u\splamenu|pozar|
                            povrijedjen\w*|povredjen\w*|(?:se\s)?onesvijesti\w*|(?:se\s)?srusi\w*)|
                    nisu\s(?:zarobljen\w*|zatrpan\w*|zaglavljen\w*|povrijedjen\w*|povredjen\w*)|
                    nema\s(?:vatre|pozara|poplave|dima|curenja)|ugasen\w*|ugasili\ssmo|
                    not\s(?:burning|on\sfire|rising|entering|trapped|buried|stuck)|
                    (?:nobody|no\sone)\sis\s(?:trapped|buried|stuck))\b/x
        # Yesterday, a drill, a film, a plan, a policy, a course, a bill — all
        # of them talk ABOUT danger without anyone being in it.
        # The endings are spelled out so this never swallows a live report:
        # "prosl\w*" would also match "proslijedi", and "plan\w*" would match
        # "planina" — and a mountain on fire is an emergency.
        NONCURRENT = /\b(?:jucer|juce|sinoc|ranije|nekada|prosl(?:a|e|i|o|u|og|om|oj|ih|im)|lani|
                        yesterday|last\sweek|last\syear|used\sto|
                        ako|ukoliko|what\sif|in\scase|film\w*|igric\w*|simulaci\w*|vjezb\w*|vezb\w*|
                        plan|plana|planu|planom|planovi\w*|planiran\w*|
                        strategij\w*|prevencij\w*|protivpozarn\w*|zastit\w*\sod|edukacij\w*|obuk\w*|kurs\w*|
                        osiguranj\w*|polis\w*|premij\w*|propis\w*|zakon\w*|pravilnik\w*|
                        birokrat\w*|dugov\w*|traffic|guzvi)\b/x
        # Only complete level questions qualify, never a home/urgency suffix.
        WATER_LEVEL_QUESTION = /\A(?:
          (?:da\s+li|je\s+li|koliko\s+brzo)\s+(?:voda|nivo\s+vode)\s+raste
            (?:\s+(?:u|na)\s+(?:(?:rijeci|reci)\s+)?(?:drini|savi|rijeci|reci))?|
          (?:is|how\s+fast\s+is)\s+(?:the\s+)?water\s+rising
            (?:\s+in\s+(?:the\s+)?(?:drina|sava|river))?
        )\z/x
        # "Ima li požara u gradu?" asks about the world; it does not report one.
        # A clause that also carries a present-tense danger verb is exempt from
        # this exemption, so "ima li nekoga unutra, gori krov" still counts.
        INFORMATION_QUESTION = /\A(?:da\sli\sima|ima\sli|koliko\sima|gdje\sima|gde\sima|is\sthere|are\sthere|
                                 kakv\w*\s(?:je\s)?(?:stanje|situacij\w*))\b/x
        PRESENT_DANGER_VERB = /\b(?:gori|gore|plamti|curi|ulazi|prodire|plavi|nadolazi|nadire|
                                zarobljen\w*|zatrpan\w*|ne\sreaguje|ne\sdise|burning|rising|entering|trapped)\b/x
        # Asking where something is PUBLISHED, or to read about it, requests
        # information ABOUT a danger; it does not report one. Until now the only
        # information guard was INFORMATION_QUESTION, which is \A-anchored and
        # covers just "ima li požara". So, measured on production 14.09.2026,
        # "gdje mogu pročitati obavještenja o požarima" got the fire card 3/3,
        # while the near-identical "gdje se objavljuju obavještenja o zaštiti od
        # požara" passed — but only because "zaštita od" happens to be in
        # NONCURRENT. "Statistika požara prošle godine" passed on "prošle" the
        # same way. Every non-escalation here was an accident of an unrelated
        # token, so the behaviour was phrasing-specific, not a reading of the
        # request, and any rephrasing fell back to the card.
        #
        # Exempt, exactly like INFORMATION_QUESTION, when the same clause also
        # carries a present-tense danger verb or says it is happening now:
        # "gdje da prijavim požar, gori mi krov" is still an emergency, and so
        # is "treba mi informacija, gori sada".
        INFORMATION_NOUN = /\b(?:obavjestenj\w*|obavestenj\w*|obavijest\w*|informacij\w*|
                              statistik\w*|izvjestaj\w*|izvestaj\w*|podatak|podac\w*|arhiv\w*|
                              notifications?|information|statistics)\b/x
        INFORMATION_VERB = /\b(?:gdje|gde|kako|odakle|where|how)\b[^.!?]{0,40}?
                             \b(?:procitat\w*|citat\w*|nac[ie]|pronac[ie]|nadjem|nadje\w*|
                                vidjet\w*|videt\w*|saznat\w*|objavljuj\w*|objavl\w*|
                                read|find|see|published)\b/x
        URGENT_NOW = /\b(?:sad|sada|upravo|trenutno|odmah|hitno|right\snow)\b/

        # --- follow-ups ----------------------------------------------------
        # A follow-up is answered from the bounded safety context, never from a
        # durable incident profile. These are whole-message intents, not topics.
        CONTACT_REQUEST = /\b(?:koga\s(?:da\s)?(?:zovem|zovemo|pozovem|zvati|zovnem)|koga\szvati|
                             kome\s(?:da\s)?(?:se\s)?javim|koji\s(?:je\s)?broj|na\skoji\sbroj|
                             daj\s(?:mi\s)?broj|treba\smi\sbroj|posalji\sbroj|broj\ssluzbe|broj\stelefona|
                             number\sto\scall|what\s?(?:s|is)?\sthe\snumber|which\snumber|
                             who\s(?:do|should|can)\si\scall|whom\sdo\si\scall|give\sme\sthe\snumber)\b/x
        SERVICE_REQUEST = {
          "medical" => /\b(?:hitn\w*\spomoc\w*|hitnu\spomoc|hitna|ambulant\w*|ambulanc\w*|ambulance|
                          doktor\w*|ljekar\w*|lekar\w*|paramedic)\b/x,
          "fire" => /\b(?:vatrogasc\w*|vatrogasn\w*|vatrogasa\w*|fire\sbrigade|fire\sdepartment|firefighters?)\b/x,
          "police" => /\b(?:polic\w*|police|mup)\b/x
        }.freeze
        # Someone is next to the danger — the reply adds the ambulance line.
        PEOPLE_PRESENT = /\b(?:(?:djeca|deca|ljudi|komsije|stanari|radnici)\ssu|
                            (?:dijete|dete|covjek|covek|komsij\w*|neko)\sje|
                            ima\sljudi|ima\snekoga|children\sare|kids\sare|people\sare|someone\sis)\b
                          [^.!?]{0,40}?
                          \b(?:unutra|pored|blizu|tu|ovdje|ovde|u\skuci|u\sstanu|u\szgradi|u\sautu|u\sliftu|
                             inside|nearby|next\sto|in\sthere|in\sthe\shouse)\b/x
        # "To je opasnost sada", "ovo se dešava sad" — the citizen is telling us
        # the turn was misread, not asking a new question.
        DANGER_ASSERTION = /\b(?:je\sopasnost|opasno\sje|to\sje\sopasno|hitno\sje|ovo\sje\shitno|
                              ovo\sse\s(?:desava|dogadja)\s(?:sad|sada)|desava\sse\s(?:sad|sada)|
                              (?:this|it)\sis\s(?:an\s)?(?:emergency|dangerous)|happening\s(?:right\s)?now)\b/x

        module_function

        # The red-zone predicate the Responder gate uses. Unchanged contract:
        # true when this message reports danger happening now.
        def call(text)
          !assess(text).nil?
        end

        # The typed danger in +text+, or nil. Never raises: a message that
        # cannot be read is not an emergency claim.
        def assess(text)
          kinds = statement_kinds(text)
          return nil if kinds.empty?

          primary = KINDS.find { |kind| kinds.include?(kind) }
          secondary = KINDS.find { |kind| kind != primary && kinds.include?(kind) }
          Assessment.new(kind: primary, also: secondary)
        rescue StandardError
          nil
        end

        # Kept so a caller can still ask the old question of one fragment.
        def dangerous_statement?(statement)
          !statement_kind(statement).nil?
        end

        # The kinds every clause of +text+ reports, deduplicated. Clause and
        # statement splitting is unchanged: guards stay local to their clause.
        def statement_kinds(text)
          value = text.to_s
          return [] if value.empty? || value.length > MAX_LENGTH

          value.split(/[.!?;,\n]|\b(?:ali|nego|but|however|[ai] sada|[ai] sad|and now)\b/i).flat_map do |part|
            clause = Text.fold(part)
            next [] if NONCURRENT.match?(clause) || WATER_LEVEL_QUESTION.match?(clause)
            next [] if information_request?(clause) && !live_danger?(clause)

            clause.split(/\b(?:and|i(?! (?:am|m)\b))\b/).filter_map { |statement| statement_kind(statement) }
          end.uniq
        end

        # A clause that asks ABOUT danger rather than reporting it: the old
        # "ima li požara" form, a request for a published notice or a statistic,
        # or a "where can I read/find" question.
        def information_request?(clause)
          INFORMATION_QUESTION.match?(clause) ||
            INFORMATION_NOUN.match?(clause) ||
            INFORMATION_VERB.match?(clause)
        end

        # What revokes the information exemption: the danger is named as
        # happening, in this same clause.
        def live_danger?(clause)
          PRESENT_DANGER_VERB.match?(clause) || URGENT_NOW.match?(clause)
        end

        # The one danger a single statement reports, or nil. The order is the
        # order the card leads with: the hazard first, the casualty last.
        def statement_kind(statement)
          return nil if DENIAL.match?(statement)
          return "fire" if fire?(statement)
          return "gas" if GAS.match?(statement)
          return "flood" if FLOOD.match?(statement)
          return "trapped" if trapped?(statement)
          return "medical" if MEDICAL.match?(statement)

          nil
        end

        def fire?(statement)
          return true if FIRE_NOUN.match?(statement) || SMOKE.match?(statement)
          return true if FIRE_VERB.match?(statement) && !FIRE_FIGURATIVE.match?(statement)

          FIRE_VERB_WITH_OBJECT.match?(statement) && FIRE_OBJECT.match?(statement)
        end

        def trapped?(statement)
          COLLAPSE.match?(statement) || NO_WAY_OUT.match?(statement) ||
            (PERSON.match?(statement) && TRAPPED.match?(statement))
        end

        # What an UNAMBIGUOUS follow-up asks for, given the danger already
        # established in this conversation. Returns nil for anything else — a
        # later question is a later question, not a continued emergency.
        #
        #   * {service:}          — the citizen named the service they want
        #   * {contact: true}     — "koga da zovem?", with no service named
        #   * {people: true}      — someone is next to the danger
        #   * {restate: true}     — "to je opasnost sada": the turn was misread
        def follow_up(text)
          folded = bounded_fold(text)
          return nil unless folded

          asked = { service: named_service(folded), contact: CONTACT_REQUEST.match?(folded),
                    people: PEOPLE_PRESENT.match?(folded), restate: DANGER_ASSERTION.match?(folded) }
          return asked if asked.fetch(:contact) || asked.fetch(:people) || asked.fetch(:restate)

          # A bare "hitna pomoć" is a follow-up only when it is the whole point
          # of the message, not when the word appears inside a longer question.
          asked.fetch(:service) && folded.split.length <= 6 ? asked : nil
        rescue StandardError
          nil
        end

        # A bare "koji je broj vatrogasaca?" with no prior emergency: the
        # citizen asked for one reviewed number and gets exactly that. The
        # length bound is what keeps this out of the way of an ordinary
        # directory question — "koji je broj policijske stanice u Janji?" is a
        # request for a station, not for 122, and belongs to the directory.
        def service_request(text)
          folded = bounded_fold(text)
          return nil unless folded && CONTACT_REQUEST.match?(folded) && folded.split.length <= 6

          named_service(folded)
        rescue StandardError
          nil
        end

        def named_service(folded)
          SERVICE_REQUEST.find { |_name, pattern| pattern.match?(folded) }&.first
        end

        # Folded text a follow-up may be read from: present, and short enough
        # that a long message cannot be mistaken for a two-word question.
        def bounded_fold(text)
          folded = Text.fold(text)
          folded.empty? || folded.length > 200 ? nil : folded
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Closed text predicates the dialogue core shares: the pre-model
        # credential boundary, the cancel and repair vocabularies, and the
        # board/area shapes of a public-activity follow-up. Every predicate is a
        # pure yes/no over one string; those marked "folded" expect the caller
        # to have applied Decidim::Bih::Text.fold already, exactly as the
        # original call sites did. Nothing here reads state or calls a model.
        module TextPredicates
          ISO_DATE = /\A\d{4}-\d{2}-\d{2}\z/

          # A conservative pre-model credential boundary, not an identity
          # verifier. A year/date or a category number remains normal dialogue.
          CREDENTIAL_PATTERNS = [
            /\A\d{6}\z/,
            %r{\A(?:\+|0)[\d\s()./-]{7,25}\z},
            /(?:\A|[^\p{L}])(?:kod|code|otp|код)\s*(?::|=|je|is|је)?\s*\d{4,8}(?!\d)/iu,
            /(?:lozinka|password|šifra|sifra|лозинка|шифра)\s+(?:je|is|је)\s+\S+/iu,
            /(?<!\w)\+\d[\d\s().-]{6,24}\d(?!\d)/,
            %r{(?:\bverify_|/v/)[A-Za-z0-9_-]{8,}|[?&](?:token|code|password|api_key)=}i,
            /(?:\b(?:password|lozinka|šifra|sifra|otp|token|kod)|лозинка|шифра|код)\s*[:=]\s*\S+/i
          ].freeze

          # First-person forms count: a citizen who writes "otkazujem" has
          # cancelled as plainly as one who writes "otkazi". Understand's own
          # CANCEL_PHRASES already carried them, so the draft path refusing
          # them meant two cancel vocabularies disagreed on the one path that
          # holds a live send token.
          CANCEL_COMMANDS = %w(odustani odustajem prekini prekidam otkaži otkazi otkazujem cancel stop
                               одустани одустајем прекини прекидам откажи отказујем).freeze
          CANCEL_FIRST_CLAUSE = /\A(?:odustajem|odustani|prekini|prekidam|otkazi|otkazujem|cancel|stop)(?: (?:od |the |this )?(?:prijav\w*|objav\w*|zadat\w*|put(?:a|ovanja)?|voznje|report|post|task|trip|journey))?\z/
          # A cancel the citizen decorated with a discourse marker or a
          # politeness: "ne, odustajem", "u redu, odustajem", "ne hvala,
          # odustani". Folding drops the comma, so all that survives of the
          # decoration is a leading word.
          #
          # CANCEL OUTRANKS CORRECTION PARSING. A leading "Ne," negates the
          # ANSWER and not the request behind it, which is right for "Ne, pitam
          # šta je MI PRE(D)UZIMAMO?" and wrong here, where the request behind
          # it IS the cancel. Live on 14.09.2026: "ne, odustajem" re-prompted
          # and the draft stayed open, while a bare "odustani" one turn later
          # still found a task to cancel. A citizen who believes they have
          # stopped must have stopped.
          #
          # Every literal space is spelled [ ] — this is an /x pattern, and /x
          # drops an unescaped one silently.
          CANCEL_DECORATION = /\A(?:ne|ni|no|nope|ok|okej|okay|u[ ]redu|dobro|vazi|hvala|
                                   da|aha|pa|ma|onda|izvini|izvinite|molim[ ]te|molim[ ]vas)[ ]/x
          # "ne hvala, odustani" carries two markers. More than two is a
          # sentence, and a sentence is not a bare cancel.
          MAX_CANCEL_DECORATIONS = 2
          LOCAL_REPAIR_PHRASES = [
            "pogresno si me razumjela", "pogresno si me razumela",
            "nisi me dobro razumjela", "nisi me dobro razumela",
            "ne nisam rekao da saljes", "ne nisam rekla da saljes"
          ].freeze
          ENGLISH_REPAIR_PHRASES = ["you misunderstood me", "that is not what i meant", "that s not what i meant"].freeze

          # == Dialogue control as bounded shapes, not closed literal lists
          #
          # Every predicate below used to be an exact-match list of six, three,
          # eight, two or four entries. A citizen who phrased the same move one
          # word differently fell through to the model, and the miss was charged
          # to the clarification budget. These are still whole-utterance (or
          # leading-clause) matches — never a substring anywhere in a sentence —
          # so they stay as conservative as the lists they replace.

          # A repair: "you got me wrong", "I already told you", "that is not
          # what I asked". It preserves the task and never means publish/cancel.
          REPAIR = /\A(?:
            (?:e[ ]|pa[ ]|ma[ ]|ne[ ]|ma[ ]ne[ ])?
            (?:
              (?:pogresno|krivo)[ ](?:si[ ])?(?:me[ ])?(?:razumjela|razumela|shvatila|protumacila)|
              nisi[ ](?:me[ ])?(?:dobro[ ]|ispravno[ ]|tacno[ ])?(?:razumjela|razumela|shvatila|cula|slusala)|
              nisam[ ](?:to[ ])?(?:te[ ])?(?:pitao|pitala|rekao|rekla|trazio|trazila)(?:[ ]to)?|
              ne[ ]nisam[ ](?:rekao|rekla)[ ]da[ ]saljes|
              (?:ja[ ])?(?:sam[ ])?(?:ti[ ])?(?:vec[ ])?(?:rekao|rekla)[ ](?:sam[ ])?(?:ti[ ])?(?:vec|to)|
              (?:to[ ])?nije[ ](?:ono[ ])?(?:sto[ ]sam[ ](?:pitao|pitala|trazio|trazila)|to)|
              ponovo[ ]te[ ](?:pitam|pitao|pitala)|
              nisi[ ](?:mi[ ])?odgovorila(?:[ ]na[ ](?:moje[ ])?pitanje)?
            )
          )[.!?]*\z/x
          ENGLISH_REPAIR = /\A(?:
            you[ ](?:mis)?understood[ ]me(?:[ ]wrong)?|that[ ](?:is|s)[ ]not[ ]what[ ]i[ ](?:meant|asked)|
            i[ ](?:already[ ])?(?:told|asked)[ ]you(?:[ ]already)?|you[ ](?:did[ ]not|didn[ ]t)[ ]answer(?:[ ]my[ ]question)?
          )[.!?]*\z/x

          # A request to go back to a task that was suspended. The bare commands
          # keep working; a sentence that NAMES the return ("vrati se na ono za
          # smeće, koji dan si rekla?") is the same move plus a question, and
          # the tail is returned so the caller can answer it inside that task.
          RESUME_REQUEST = /\A(?:
            (?:hajde[ ]|ajde[ ]|molim[ ]te[ ]|a[ ])?
            (?:vrati[ ](?:se|mo[ ]se)|vratimo[ ]se|idi[ ]nazad|nazad|nastavi(?:mo)?|
             (?:go[ ])?back|let[ ]s[ ](?:go[ ]back|return)|return)
            [ ](?:na|na[ ]ono|na[ ]onu|na[ ]onaj|to|to[ ]the|to[ ]that)[ ]
          )(?<tail>.+)\z/x
          # The clause separators a trailing question may hang off.
          RESUME_TAIL_SPLIT = /[,;]\s*|\s+-\s+/

          # "kraće", "detaljnije": a request about the PRESENTATION of the
          # answer already given, never a new task and never a cancellation.
          #
          # The sentence-count forms ("može odgovor u najviše dvije rečenice?")
          # are the same move spelled out. They were not recognised at all, so
          # the turn was re-classified from scratch and a brevity request about
          # a report-privacy answer came back as the 957-character Sistem 48
          # catalogue — longer than what it asked to shorten.
          PRESENTATION_REQUEST = /\A(?:
            (?:molim[ ]te[ ]|molim[ ]|mozes[ ]li[ ]|mozete[ ]li[ ]|moze[ ]li[ ]|moze[ ]|daj[ ]|a[ ]|i[ ]|ok[ ]|dobro[ ])*
            (?:odgovor[ ]|odgovori[ ]|reci[ ][^ ]*[ ]?)?
            (?:
              (?:jos[ ])?(?:krace|kratko|ukratko|sazetije|sazeto|skraceno|najkrace)|
              u[ ](?:najvise[ ])?(?:jednoj|dvije|dve|dv[ae]|tri|par|nekoliko)[ ]recenic\w*|
              u[ ]jednoj[ ]recenici|jednom[ ]recenicom|jedna[ ]recenica|
              (?:najvise[ ])?(?:dvije|dve|tri)[ ]recenic\w*|
              detaljnije|opsirnije|vise[ ]detalja|cijeli[ ]spisak|prikazi[ ]sve|
              (?:even[ ]|much[ ])?shorter|briefly|in[ ]short|be[ ]brief|keep[ ]it[ ]short|
              (?:in[ ])?(?:one|two|three)[ ]sentences?|more[ ]detail(?:s)?|full[ ]list|show[ ]all
            )
            (?:[ ](?:molim|te[ ]molim|please|molim[ ]te))*
            (?:[ ](?:jer[ ]|posto[ ]|because[ ])?(?:citam[ ]na[ ](?:telefonu|mobitelu)|
              na[ ]telefonu[ ]sam|tesko[ ]citam|i[ ]am[ ]reading[ ]on[ ](?:my[ ])?phone))?
          )[.!?]*\z/x

          # A presentation modifier may name the facts to keep, but cannot
          # carry a new question or action. The retained answer owns this turn.
          PRESENTATION_MODIFIER = /\A(?:mozes[ ]li[ ](?:napisati[ ])?)?(?:kratko|krace|ukratko|sazeto)
            (?:[ ](?:i[ ]jasno|bez[ ]obecanja|bez[ ]neprovjerenih|odvoji|i[ ]jasno[ ]odvoji|gdje[ ]ulazim)[^\n]{0,120})\z/x
          SCRIPT_REQUEST = /\A(?:molim[ ](?:te[ ])?|mozes[ ]li[ ]|odgovori[ ]|napisi[ ]|pisi[ ]|ponovi[ ])*
            (?:to[ ]|isto[ ]|odgovor[ ])?(?:na[ ])?(?<script>cirilic(?:[ai]|om)|latinic(?:[ai]|om))(?:[ ]molim)?\z/x

          def self.presentation_locale(text)
            match = SCRIPT_REQUEST.match(Decidim::Bih::Text.fold(text.to_s))
            return unless match

            match[:script].start_with?("cirilic") ? "sr-Cyrl" : "sr"
          end

          # These constraints refine a public lookup; they cannot cancel a
          # report, open a write flow or invent source facts.
          def self.read_follow_up_kind(text, state)
            return unless state["active_task"] == "ask_information" && !state["draft"]
            return if %w(account privacy report neighborhood).include?(state["topic"])

            query = Decidim::Bih::Text.fold(text.to_s)
            return "read_only" if query.match?(/\Ane[ ]zelim[ ](?:da[ ])?(?:napravim|podnesem|posaljem)[ ]prijavu\z/)
            return "missing_detail" if query.match?(/\A(?:odgovor[ ]nije[ ]koristan[ ])?(?:reci|objasni)[ ]sta[ ]ti[ ](?:nedostaje|treba)[ ]da[ ]provjeris\z/)
            return unless state["topic"] == "transport"

            return "transport_window" if retained_transport_window_reminder?(query, state)

            if query.match?(/\Anemoj[ ](?:obecati[ ]vezu[ ]ako[ ]nema[ ]potvrdjenog[ ]drugog[ ]polaska|izmisliti[ ]nocnu[ ]autobusku[ ]liniju)\z/)
              "verified_transport"
            end
          end

          # A request not to relabel an earlier departure is a constraint on
          # the existing time window, not an unspecified correction. Reject
          # new clocks, dates, endpoint changes and unrelated tasks so their
          # ordinary correction/routing paths still receive the whole message.
          def self.retained_transport_window_reminder?(query, state)
            entities = state.fetch("entities", {})
            return false if entities["time_expression"].to_s.empty?
            return false unless query.length.between?(10, 180)
            return false if /[0-9]|\b(?:sutra|preksutra|nego|umjesto|umesto|nalog|registr\w*|lozink\w*|prijav\w*|objav\w*|bodov\w*|odredist\w*)\b/.match?(query)
            return false unless /\A(?:nemoj[ ](?:navesti|navoditi|nuditi|ponuditi|prikazati)|ne[ ](?:navodi|nudi|prikazuj))\b/.match?(query)

            /\b(?:autobus\w*|pola[sz]\w*)\b/.match?(query) &&
              /\b(?:jutarnj\w*|ranij\w*|pros\w*)\b/.match?(query) &&
              /\b(?:slijedi|sledi|sljedec\w*|sledec\w*|naredn\w*|kasnij\w*|veceras|nocas)\b/.match?(query)
          end

          # == The elliptical follow-up
          #
          # A second message whose subject is only in the FIRST one: "A kad se
          # završava trka?", "a za djecu?", "A koliko za registraciju?". It
          # names no entity and no topic, so classifying it from scratch lands
          # it wherever the broadest matcher happens to reach — in the rated
          # corpus, the rewards catalogue.
          #
          # Two bounds keep this narrow. It must OPEN with a continuation
          # particle (the "a"/"i"/"pa" that makes it a continuation at all),
          # and it must be short: a sentence with room for its own subject is
          # not an ellipsis. Everything a cold matcher already recognises is
          # excluded by the caller before this is ever consulted.
          ELLIPSIS_FOLLOW_UP = /\A(?:a|i|pa|te|and|what[ ]about|how[ ]about)\b[^\n]{0,60}\z/
          # Leading acknowledgements that carry no request of their own. They
          # are not part of the question, but they are what stopped "Dobro, a
          # ko trenutno vodi?" from matching the standings route that "a ko
          # trenutno vodi?" matches. "a", "i" and "pa" are deliberately NOT
          # here: the routes already accept them, and they are the marker.
          LEADING_FILLER = /\A(?:dobro|ok|okej|okay|u\sredu|aha|aham|jasno|razumijem|razumem|
                              va[žz]i|hajde|ajde|e\spa|pa\sdobro|dobro\sonda|onda|zna[čc]i|dakle|
                              alright|right|got\sit|i\ssee|fine)[\s,;:.!-]+/ix
          MAX_FILLER_STRIPS = 3

          # "A drugo pitanje?", "A treće?" — a reference to a question the
          # citizen asked EARLIER and was never answered, not to the answer
          # they just got. Remembering the last answered subject cannot recover
          # an unanswered queue, and continuing from that subject answers the
          # wrong one of their questions, so a continuation declines these
          # outright. Queued questions need their own owner; see the report.
          QUEUED_QUESTION = /\A(?:a[ ]|i[ ]|pa[ ])?
            (?:(?:sta[ ]je[ ]s[ ])?(?:sa[ ])?)?
            (?<ordinal>prvo|drugo|trece|cetvrto|peto|prvi|drugi|treci|ostal[oa]|
               first|second|third|other)
            (?:[ ](?:pitanje|pitanja|dio|dijelu|dijela|part|question))?
          [.!?]*\z/x
          # WHICH of the citizen's own questions the ordinal names, one-based.
          # "ostalo"/"other" is deliberately absent: it names no position, and
          # nothing here knows which of the list has already been served, so it
          # keeps declining exactly as the whole family used to.
          QUEUED_ORDINALS = {
            "prvo" => 1, "prvi" => 1, "first" => 1,
            "drugo" => 2, "drugi" => 2, "second" => 2,
            "trece" => 3, "treci" => 3, "third" => 3,
            "cetvrto" => 4, "peto" => 5
          }.freeze

          # "Šta si ono rekla?", "Ponovi mi to." — a request for the SAME answer
          # again. It was recognised nowhere in the dialogue, so it was
          # classified as a new question and answered with a different subject.
          REPEAT_REQUEST = /\A(?:
            (?:a[ ]|pa[ ]|ma[ ]|e[ ])?
            (?:
              sta[ ]si[ ](?:ono[ ]|to[ ])?(?:rekla|rekao|kazala|kazao)(?:[ ](?:ono|to))?|
              (?:mozes[ ]li[ ](?:mi[ ])?)?ponovi(?:ti|s|te)?(?:[ ](?:mi|to|ono|jos[ ]jednom|ponovo|opet))*|
              jos[ ]jednom(?:[ ]to)?|
              (?:can[ ]you[ ])?(?:say[ ]that[ ]again|repeat[ ](?:that|it))|what[ ]did[ ]you[ ]say
            )
            (?:[ ](?:molim|molim[ ]te|please))?
          )[.!?]*\z/x

          # == The contrastive correction
          #
          # "Ne pitam za parking. Pitam da li je korišćenje ove platforme
          # besplatno." A repair that CARRIES ITS OWN INFORMATION: it names
          # what was wrong and what was meant. Answering it with an apology and
          # a question hands the work back to the citizen; answering it with
          # 512 more characters of parking is worse.
          #
          # The negated clause must OPEN the sentence. Wording that negates one
          # action inside a positive request ("treba mi službena stranica, ne
          # prijava problema") is a contrastive correction of a different kind
          # and is already handled by +cancel_action?+; it is not this.
          FEEDBACK_CORRECTION_PREFIX = /\A\s*(?:nije\s+korisno|није\s+корисно|not\s+helpful)\s*[,;:.!-]+\s*(?<request>.+)\z/im
          FEEDBACK_REQUEST = /\A(?:pitam|pitao\s+sam|pitala\s+sam|zanima(?:ju)?\s+me|treba\s+mi|zelim|kako|kada|gdje|gde|i\s+asked|i\s+want|how|when|where)\b/
          CORRECTION_SPLIT = /(?<=[.!?;])\s+|\s+(?:nego|vec|ali|but|rather)\s+/
          # A bare "Ne," in front of a request negates the ANSWER, not the
          # request that follows it: "Ne, pitam šta je MI PRE(D)UZIMAMO?" asks
          # the newcomer question. Folding drops the comma, so the raw clause
          # is what decides.
          DISCOURSE_NO = /\A\s*(?:ne|ni|no|nope)\s*[,;:-]/i
          NEGATED_REQUEST = /\A(?:ja[ ])?(?:
            (?:ne|niti)[ ](?:te[ ])?(?:pitam|trazim|zanima[ ]me|trebam|treba[ ]mi|zelim|hocu|mislim|govorim|pricam)|
            (?:nisam|nisi)[ ](?:te[ ])?(?:to[ ]|ovo[ ]|ono[ ])?(?:pitao|pitala|trazio|trazila|mislio|mislila|rekao|rekla)|
            (?:i[ ])?(?:am[ ]not|m[ ]not|do[ ]not|don[ ]t)[ ]ask(?:ing)?|not[ ]asking
          )\b(?<subject>[^\n]{0,80})\z/x
          # What is left of the negated clause once the verb is gone.
          NEGATED_SUBJECT_LEAD = /\A(?:za|o|na|u|oko|about|for|the)\s+/
          NEGATED_PRONOUN = /\A(?:to|ovo|ono|ta|taj|tu|te|that|this|it)\z/

          # A question that REFERS BACK to the answer just given: "koji je tačan
          # datum i sat roka?", "a koji je njihov broj telefona?". It is a
          # refinement of the task in hand, not a new one — but it carries no
          # slot and names no topic, so the model classifies it as a switch and
          # the retained question gets answered instead of this one.
          BACK_REFERENCE = /\A(?:a[ ]|i[ ]|pa[ ])?
            (?:koji|koja|koje|kojeg|kada|kad|gdje|gde|koliko|sta|sto|da[ ]li|
             what|when|where|how|which|is[ ]it|does[ ]it)\b
            [^\n]{0,80}?
            \b(?:tacan|tacno|tacnog|tacnu|taj|tog|toga|tom|tu|te|to|ta|isti|istog|istu|
               njihov|njihova|njihovo|njihovog|njihovu|njen|njena|njeno|
               that|this|those|these|their|its|it)\b/x

          # A cancellation the citizen actually asked for. Wording that only
          # NEGATES one action inside a positive request ("I want the official
          # page, not a problem report") is a contrastive correction, so the
          # negated-action pattern only counts in the FIRST clause — which is
          # where an actual cancellation lives.
          CANCEL_CLAUSE_SEPARATOR = /\s+(?:ali|nego|vec|but|rather)\s+/

          # A komšiluk board/member question is private context; a public-activity
          # refinement must not continue from it.
          BOARD_CONTEXT = /\b(?:objav\w*|tabl\w*|ploc\w*|posts?|board|clanov\w*|members?)\b/
          # "mz <name>" / "komsiluk <name>" with no second clause is an area, not a new request.
          QUALIFIED_AREA = /\A(?:mz|komsiluk) [a-z0-9][a-z0-9 -]{0,99}\z/
          AREA_EXTRA_CLAUSE = /\b(?:i|ili|ali|pa|onda|ne|nije|nemoj|prijavi|objavi|posalji|and|or|u|na|za|od|do|danas|sutra|uskoro|vikend\w*|today|tomorrow|soon)\b/

          module_function

          # Raw text (not folded): the patterns carry their own case and script handling.
          def credential?(text)
            value = text.to_s.strip
            return false if value.empty? || value.match?(ISO_DATE)

            CREDENTIAL_PATTERNS.any? { |pattern| value.match?(pattern) }
          end

          # Folded whole utterance.
          def cancel_command?(folded)
            CANCEL_COMMANDS.include?(folded)
          end

          # Folded first clause of a "cancel, then a new question" message.
          def cancel_first_clause?(folded)
            CANCEL_FIRST_CLAUSE.match?(folded)
          end

          # Folded whole utterance: a bare cancel standing behind at most two
          # discourse markers. What remains once they are stripped must itself
          # be a cancel and nothing else, so a message that carries a request
          # of its own can never reach this — "ne pitam za parking" strips to
          # "pitam za parking", which is not a cancel, and stays a correction.
          def decorated_cancel?(folded)
            return false unless folded.is_a?(String) && folded.length <= 80

            remainder = folded.strip
            MAX_CANCEL_DECORATIONS.times do
              match = CANCEL_DECORATION.match(remainder)
              break unless match

              remainder = remainder[match.end(0)..].to_s.strip
              return true if cancel_command?(remainder) || cancel_first_clause?(remainder)
            end
            false
          end

          # Folded whole utterance. The literal list is kept as the floor; the
          # shape recognises the same move phrased differently.
          def local_repair_phrase?(folded)
            LOCAL_REPAIR_PHRASES.include?(folded) || REPAIR.match?(folded)
          end

          # Folded whole utterance.
          def english_repair_phrase?(folded)
            ENGLISH_REPAIR_PHRASES.include?(folded) || ENGLISH_REPAIR.match?(folded)
          end

          # Folded whole utterance: a question that refers back to the answer
          # just given rather than naming a new subject.
          def back_reference?(folded)
            folded.is_a?(String) && folded.length <= 160 && BACK_REFERENCE.match?(folded)
          end

          # Folded whole utterance: a presentation request about the answer
          # already given ("kraće", "detaljnije"), carrying nothing else.
          def presentation_request?(folded)
            (PRESENTATION_REQUEST.match?(folded) || SCRIPT_REQUEST.match?(folded) ||
              (PRESENTATION_MODIFIER.match?(folded) && !folded.match?(/\b(?:kako|kada|koliko|prijavi|obrisi|registruj|posalji)\b/)))
          end

          # The question a sentence-form return request carries with it, or nil
          # when the request is bare. +text+ is the raw citizen text; the tail
          # is returned in the citizen's own words, never folded.
          def resume_request_tail(text)
            return unless text.is_a?(String) && text.length <= 200

            match = RESUME_REQUEST.match(Decidim::Bih::Text.fold(text))
            return unless match

            tail = text.strip.split(RESUME_TAIL_SPLIT, 2)[1].to_s.strip
            tail.empty? ? nil : tail
          end

          # Folded whole utterance (or leading clause): a sentence-form return
          # request such as "vrati se na ono za smeće, koji dan si rekla?".
          def resume_request?(text)
            return false unless text.is_a?(String) && text.length <= 200

            RESUME_REQUEST.match?(Decidim::Bih::Text.fold(text))
          end

          # Folded, punctuation-stripped utterance. True only when the
          # negated-action wording is the FIRST clause: "ne prijavljuj to" is a
          # cancellation, "treba mi stranica, ne prijava problema" is not.
          def cancel_action?(folded, pattern)
            return false unless folded.is_a?(String)

            first = folded.split(CANCEL_CLAUSE_SEPARATOR, 2).first.to_s
            match = pattern.match(first)
            return false unless match

            # Anything before the negation must itself be a lead-in, not a
            # request of its own ("nemoj objaviti" / "molim te ne prijavljuj").
            lead = first[0...match.begin(0)].to_s.strip
            lead.empty? || lead.split.length <= 2
          end

          # Folded query text.
          def board_context?(folded)
            BOARD_CONTEXT.match?(folded)
          end

          # Folded span; true only for a bare qualified area with no extra clause.
          def qualified_area?(folded)
            QUALIFIED_AREA.match?(folded) && !AREA_EXTRA_CLAUSE.match?(folded)
          end

          # Folded whole utterance: an elliptical follow-up whose subject is in
          # the PREVIOUS turn. See ELLIPSIS_FOLLOW_UP.
          def ellipsis_follow_up?(folded)
            folded.is_a?(String) && folded.length.between?(2, 80) && ELLIPSIS_FOLLOW_UP.match?(folded)
          end

          # Folded whole utterance: a reference to an earlier, unanswered
          # question of the citizen's own. See QUEUED_QUESTION.
          def queued_question?(folded)
            folded.is_a?(String) && folded.length <= 40 && QUEUED_QUESTION.match?(folded)
          end

          # WHICH one they mean, one-based, or nil. Selection only: whether a
          # question exists at that position is QuestionQueue's business, and
          # whether the turn may be answered from it is the coordinator's.
          def queued_question_ordinal(folded)
            return unless queued_question?(folded)

            QUEUED_ORDINALS[QUEUED_QUESTION.match(folded)[:ordinal]]
          end

          # Folded whole utterance: "say that again".
          def repeat_request?(folded)
            folded.is_a?(String) && folded.length <= 80 && REPEAT_REQUEST.match?(folded)
          end

          # The citizen's own words with the leading acknowledgement removed.
          # Raw text in, raw text out: the remainder is still what they wrote,
          # so a matcher downstream sees the same sentence it would have seen
          # had the citizen not said "Dobro," first. Returns the input
          # unchanged when there is nothing to strip, or when stripping would
          # leave nothing to ask about.
          def strip_leading_filler(text)
            return text unless text.is_a?(String)

            remainder = text.strip
            return remainder if remainder.length > 200

            MAX_FILLER_STRIPS.times do
              match = LEADING_FILLER.match(remainder)
              break unless match

              candidate = remainder[match.end(0)..].to_s.strip
              break if candidate.empty? || !candidate.match?(/\p{L}/)

              remainder = candidate
            end
            remainder
          end

          # The two halves of a contrastive correction, or nil when this is not
          # one. +negated+ is the subject the citizen says they did NOT ask
          # about (nil when they only said "not that"); +positive+ is the
          # request they did make (nil when they made none). Both are returned
          # in the citizen's own words, never folded.
          def contrastive_correction(text)
            return unless text.is_a?(String) && text.length.between?(4, 300)

            feedback = feedback_correction(text)
            return feedback if feedback

            clauses = text.strip.split(CORRECTION_SPLIT).map(&:strip).reject(&:empty?)
            index = clauses.index do |clause|
              !clause.match?(DISCOURSE_NO) && NEGATED_REQUEST.match?(Decidim::Bih::Text.fold(clause))
            end
            return if index.nil?

            positive = clauses[(index + 1)..].to_a.join(" ").strip
            { "negated" => negated_subject(clauses[index]), "positive" => (positive unless positive.empty?) }
          end

          def feedback_correction(text)
            feedback = FEEDBACK_CORRECTION_PREFIX.match(text)
            return unless feedback && FEEDBACK_REQUEST.match?(Decidim::Bih::Text.fold(feedback[:request]))

            # Keep the full request, including its negative constraints. This
            # parses dialogue intent; it never records or changes a rating.
            { "negated" => nil, "positive" => feedback[:request].strip }
          end

          # The subject inside a negated clause: "ne pitam za parking" ->
          # "parking". nil when the citizen negated a pronoun ("nisam to
          # pitala") and therefore named no subject at all.
          def negated_subject(clause)
            match = NEGATED_REQUEST.match(Decidim::Bih::Text.fold(clause))
            return if match.nil?

            subject = match[:subject].to_s.strip.sub(NEGATED_SUBJECT_LEAD, "").strip
            return if subject.empty? || !subject.match?(/\p{L}/) || subject.match?(NEGATED_PRONOUN)

            subject[0, 80]
          end
        end
      end
    end
  end
end

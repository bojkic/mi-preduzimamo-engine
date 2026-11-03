# frozen_string_literal: true

require "i18n"
require_relative "contracts"
require_relative "account_question"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Reviewed public explanations that must never depend on the model:
        # the vote-integrity invariant, privacy, the newcomer introduction, the
        # launch-invitation policy, the neighbourhood race, who runs and who
        # funds the platform, what Milica herself can and cannot do, where a
        # proposal is submitted, and how to reach the foundation.
        #
        # == Why these are deterministic
        #
        # Every one of them is a POLICY question whose answer is already
        # decided, written down and reviewed. Asking a provider to phrase it
        # invites three failures the rated corpus actually produced: the model
        # confirmed a false premise about points buying influence, it answered
        # "what do you do with my data" with the bot's own source inventory, and
        # it answered an invitation deadline with an unrelated public call's
        # deadline. A reviewed sentence cannot do any of those.
        #
        # == What this module is and is not
        #
        # It is pure: text in, a card out, and the rendered copy for a card. It
        # holds no state, performs no read, writes nothing and makes no model
        # call. The PreModelStage in +public_information_stage.rb+ is the only
        # caller that turns a card into a turn result, and it does so WITHOUT
        # writing conversation state — an unfinished report draft or a pending
        # confirmation survives one of these answers untouched.
        #
        # Safety, credentials, allegations and courtesy are decided by
        # Coordinator.control_reply BEFORE any stage runs, so they keep
        # precedence over every card here by construction.
        module PublicInformation
          # Deliberately shorter than CivicQuestion's 160: these are short
          # policy questions. A long message is prose, a report or a paste, and
          # a card is the wrong answer for it.
          MAX_LENGTH = 200

          Card = Data.define(:name, :answer_intent)

          VOTE_INTEGRITY = Card.new(name: "civic_vote_integrity", answer_intent: "goodwill")
          VOTE_WITHOUT_POINTS = Card.new(name: "civic_vote_without_points", answer_intent: "goodwill")
          RACE_SCOPE = Card.new(name: "civic_race_scope", answer_intent: "launch")
          PRIVACY = Card.new(name: "civic_privacy", answer_intent: "privacy")
          NEWCOMER = Card.new(name: "civic_newcomer", answer_intent: "help")
          LAUNCH_NOT_SPENT = Card.new(name: "launch_invitation_not_spent", answer_intent: "launch")
          LAUNCH_CONFIRMATION = Card.new(name: "launch_invitation_confirmation", answer_intent: "launch")
          LAUNCH_DEADLINE = Card.new(name: "launch_invitation_deadline", answer_intent: "launch")
          LAUNCH_ELIGIBILITY = Card.new(name: "launch_invitation_eligibility", answer_intent: "launch")
          RACE_PRIZE = Card.new(name: "race_prize", answer_intent: "launch")
          RACE_OVERVIEW = Card.new(name: "race_overview", answer_intent: "launch")
          FOUNDATION_CONTACT = Card.new(name: "foundation_contact", answer_intent: "participation_guidance")
          FOUNDATION_PHONE = Card.new(name: "foundation_phone_unknown", answer_intent: "participation_guidance")
          PLATFORM_OPERATOR = Card.new(name: "civic_platform_operator", answer_intent: "help")
          FUNDING = Card.new(name: "civic_funding", answer_intent: "help")
          IDENTITY = Card.new(name: "civic_identity", answer_intent: "privacy")
          CHAT_MESSAGING = Card.new(name: "civic_chat_messaging", answer_intent: "setup")
          FEEDBACK = Card.new(name: "civic_feedback", answer_intent: "help")
          FEEDBACK_CONTROLS = Card.new(name: "civic_feedback_controls", answer_intent: "help")
          PHONE_CHANGE = Card.new(name: "civic_phone_change", answer_intent: "setup")
          PROPOSAL_ROUTE = Card.new(name: "civic_proposal_route", answer_intent: "participation_guidance")

          # --- vote integrity -------------------------------------------------
          #
          # Six turns across three rated sessions asked whether points buy vote
          # weight or proposal prominence and were never told no. The subject
          # covers every currency a citizen could believe buys influence —
          # points, donations and race standing — and the claim covers the three
          # things the invariant denies: the vote, the ranking and visibility.
          INFLUENCE_SUBJECT = /(?:bodov|poen|doprinos|donacij|donir|trka komsiluka|trke komsiluka|points)/
          # "moc" carries a negative lookbehind because "pomoc" contains it: a
          # citizen asking for help with their points must not be answered with
          # a denial they did not ask for.
          # Every literal space is spelled [ ]. This pattern was a one-line
          # regex with real spaces until it was widened and wrapped in /x to
          # span three lines; /x drops literal spaces, so that silently killed
          # five alternatives that had been matching — "vise vrijedi",
          # "vise vredi", "vazi vise", "vrh liste" and "na vrh". The widening
          # added working single words and removed working phrases in the same
          # commit, and nothing failed, because no test named the phrases.
          INFLUENCE_CLAIM = /(?:glas|tezin|vise[ ]vrijedi|vise[ ]vredi|vazi[ ]vise|rang|vrh[ ]liste|na[ ]vrh
                              |vidljiv|vidjenij|videnij|istaknut|promov|vote|voting|rank|visibility
                              |(?<![a-z])moc|uticaj|utjecaj|prednost|prioritet)/x
          # Deciding is the one word that belongs to BOTH questions a citizen
          # can ask about money and projects, and which of the two it is cannot
          # be read off the word:
          #
          #   "Imam li prednost pri odlucivanju ako doniram?" is a CLAIM - the
          #     money is said to buy a better position IN the deciding.
          #   "Gdje mogu vidjeti kako se trose donacije i ko odlucuje o
          #     projektima?" is TRANSPARENCY - who the decider is, and where
          #     that is published.
          #
          # "odluciv|odlucuj" was a plain alternative of INFLUENCE_CLAIM, and
          # "donacij" is an INFLUENCE_SUBJECT, so on 14.09.2026 the second
          # question was answered with the vote-integrity card: a flat "Ne."
          # denying a claim the citizen had not made, about a subject they had
          # not raised, instead of the answer they asked for (131 -> 362
          # characters).
          #
          # The rule: deciding names the ARENA of an influence claim, never the
          # claim itself, so it counts only when nobody is asking WHO decides.
          # Every phrasing that genuinely claims influence over a decision also
          # says what the advantage IS - "vecu moc", "prednost", "vazi vise" -
          # and those alternatives above still carry such a sentence on their
          # own. An interrogative "ko ... odlucuje/odlucio" is a transparency
          # question whatever currency the sentence also names.
          #
          # The boundary this deliberately does not try to read: a RELATIVE
          # "ko" ("da li onaj ko donira odlucuje") is vetoed too. Telling the
          # relative pronoun from the interrogative needs more than a regexp,
          # and the trade is one missed denial on a rare phrasing against a
          # wrong denial on every transparency question.
          DECIDING = /odluc/
          DECIDER_IDENTITY = /(?<![a-z])ko(?:[ ][a-z0-9]+){0,3}[ ]odluc/
          # A bare follow-up about a proposal's position, with the currency left
          # implicit ("a da li podižu rang mog prijedloga?").
          PROPOSAL_PROMINENCE = /(?:rang\s+(?:(?:mog|moga|mojeg|svog|svojeg)\s+)?prijedlog
                                  |prijedlog\w*\s+(?:na\s+)?vrh|vrh\s+liste|vidljivost\s+prijedlog
                                  |prijedlog\s+bude\s+vi[dj]+enij|istaknut\w*\s+prijedlog|pom[jl]?er\w*\s+prijedlog
                                  |podign\w*\s+(?:\w+\s+){0,2}prijedlog|prijedlog\w*\s+(?:\w+\s+){0,2}na\s+listi)/x

          # --- privacy --------------------------------------------------------
          #
          # "moji podaci" used to reach the bot's own corpus-status answer, which
          # named the model provider, the SMS gateway, the accounting system, the
          # scrape cadences and the stale sources — to an anonymous visitor.
          PRIVACY_POLICY = /(?:politik\w*\s+privatnosti|pravila\s+privatnosti|privacy\s+policy|zastit\w*\s+podataka|obrad\w*\s+podataka|politik\w*\s+kolacica|gdpr)/
          MY_DATA = /(?:moj\w*\s+podat|moj\w*\s+podac|mojim\s+podacima|moje\s+podatke|mojih\s+podataka
                      |podatke\s+o\s+meni|podaci\s+o\s+meni|podataka\s+o\s+meni|licn\w*\s+podat
                      |my\s+data|my\s+personal\s+data|moj\s+broj\s+telefona|broj\s+telefona\s+sa?\s+mog)/x
          DATA_ACTION = /(?:prodaj|prodat|prodav|ustup|dijelite|delite|dajete|proslje[dj]|prosle[dj]
                          |sta\s+radite|sta\s+se\s+radi|cuvate|koje\s+podatke|ko\s+vidi|vide|vidi\s+li
                          |javno|reklam|oglasiv|marketin|strank|trec)/x
          # Report privacy ("ko vidi moju prijavu", "anonimna prijava") is the
          # report explanation, not the data-protection policy. Decline it here.
          REPORT_PRIVACY = /(?:prijav|anonimn)/

          # --- newcomer -------------------------------------------------------
          #
          # "Ko ste vi?", "Šta je MI PRE(D)UZIMAMO?" and "Šta mogu da uradim
          # ovdje?" all returned the same canned disambiguation stub. Folding
          # removes the punctuation, so "MI PRE(D)UZIMAMO" arrives as
          # "mi pre d uzimamo" and "sta je mi\b" is what actually matches it.
          NEWCOMER_QUESTION = Regexp.union(
            /\bko\s+ste\s+vi\b/,
            /\bko\s+si\s+ti\b/,
            /\bsta\s+je\s+mi\b/,
            /\bsta\s+je\s+(?:ova|ovo|vasa)\s+platforma\b/,
            /\bsta\s+je\s+platforma\b/,
            /\bcime\s+se\s+bavi\s+(?:ova\s+|ovo\s+|vasa\s+)?platforma\b/,
            /\bsta\s+radi\s+(?:ova\s+)?platforma\b/,
            /\bcemu\s+sluzi\s+(?:ova\s+)?platforma\b/,
            /\bsta\s+je\s+svrha\s+(?:ove\s+)?platforme\b/,
            /\bsta\s+mogu\s+(?:da\s+)?(?:uradim|uraditi|radim|napravim)\s+
             (?:ovdje|ovde|tu|na\s+platformi|na\s+ovoj\s+platformi|na\s+mi\b|za\s+svoj\s+kraj|za\s+svoju\s+ulicu|za\s+svoj\s+komsiluk)/x,
            /\bprvi\s+put\s+sam\s+(?:ovdje|ovde|na\s+mi\b|na\s+platformi|na\s+ovoj\s+platformi)/,
            /\bwho\s+are\s+you\b/,
            /\bwhat\s+is\s+mi\b/,
            /\bwhat\s+is\s+this\s+platform\b/
          )

          # --- launch invitation ----------------------------------------------
          #
          # The launch anchor. A launch-policy question must never be read as a
          # question about a Grad Bijeljina public call ("javni poziv"): the
          # city-service keyword matcher is a SUBSTRING matcher and "pozivnicu"
          # contains "poziv", which is how an SME call's 17.09. deadline was once
          # returned as the invitation deadline.
          LAUNCH_ANCHOR = /(?:pozivnic|lansiranj|17\s+septemb|17\s+9\b)/
          # An explicit public-call term means the citizen really did ask about a
          # konkurs. Leave those to the public-calls reader.
          PUBLIC_CALL_TERM = /(?:javni\s+poziv|javnog\s+poziva|javnom\s+pozivu|javne\s+pozive|javnih\s+poziva|konkurs|natjeca|stipendij|subvencij|grant|\bmsp\b|mala\s+i\s+srednja)/
          LAUNCH_COST = /(?:oduzim|skida|skidaju|se\s+skine|kost|tros|potros|cijen|cena|naplac|placa|plati)/
          LAUNCH_CONFIRM = /(?:potvrd|72\s*(?:sat|h\b)|propada|propadne|propast|gubim|izgubim|ponist|ne\s+javim|otkaz|vraca\s+se)/
          LAUNCH_DEADLINE_CUE = /(?:do\s+kada|dokad|\brok\b|\broka\b|\broku\b|datum|koji\s+sat|koliko\s+sati|najkasnije|ste[c]\w*\s+pravo|istice|isteka|zadnji\s+dan|krajnji)/
          LAUNCH_ELIGIBILITY_CUE = /(?:bez\s+registracije|bez\s+naloga|bez\s+profila|ranije\s+do[dj]+em|do[dj]+em\s+ranije
                                     |na\s+vratima|na\s+ulazu|e\s*mail|mejl|bez\s+potvr[dj]+enog|bez\s+verifikovanog
                                     |ko\s+moze|mogu\s+li\s+dobiti)/x

          # --- race -----------------------------------------------------------
          # "trka" declines to "trci"/"trku": the stem alternates k/c.
          RACE_ANCHOR = /\btr[kc][aeiou]\b/
          RACE_CONTEXT = /(?:komsiluk|susjedstv|\bsel[oau]\b|grad|3\s*000|nagrad|\blig|bodov|poen|pobjed|pobed)/
          RACE_PRIZE_CUE = /(?:3\s*000|nagrad|\bkm\b|novac|novc|sta\s+se\s+dobij|koliko\s+(?:se\s+)?dobij
                             |koliko\s+para|koliko\s+novca|pobjednik|pobednik|prvo\s+m[je]sto)/x
          # The race as a citizen names it WITHOUT the word "trka". The client
          # split it into a city league and a village league, and "Koliko
          # dobija pobjednik svake lige?" is the prize question in that
          # vocabulary; it reached the rewards catalogue because RACE_ANCHOR
          # only knows the stem tr[kc]-.
          LEAGUE_ANCHOR = /\blig[aeiu]\b/
          RACE_WINNER_CUE = /(?:pobjednik\w*|pobednik\w*|pobjeduj\w*|pobjedi\w*|pobedi\w*|prvak\w*|prvo[ ]m[je]sto)/x
          # A football league is not the neighbourhood race. Without this a
          # sports question would be answered with 3.000 KM and a komsiluk.
          SPORTS_TERM = /(?:fudbal\w*|nogomet\w*|kosark\w*|odbojk\w*|rukomet\w*|utakmic\w*|\bklub\w*
                          |reprezentacij\w*|premijer[ ]lig|prvenstv\w*|\bderbi\w*)/x

          # --- foundation -----------------------------------------------------
          FOUNDATION_NAME = /(?:lokaln\w*\s+fondacij|fondacij\w*\s+bijeljin|\bfondacij|\blfbn\b|local\s+foundation)/
          FOUNDATION_CONTACT_CUE = /(?:telefon|\bbroj\b|kontakt|adres|gdje\s+se\s+nalaz|gde\s+se\s+nalaz
                                     |gdje\s+ste|gde\s+ste|e\s*mail|mejl|\bmail\b|sjedist|sedist
                                     |kancelarij|\bured\b|sajt|web\s*(?:sajt|stranic)?|stranic)/x
          FOUNDATION_PHONE_CUE = /(?:telefon|\bbroj\b|nazov|pozvati|phone)/

          # --- who runs the platform, and what it costs -------------------------
          #
          # "Ko vodi platformu MI PRE(D)UZIMAMO?" was answered with birth
          # certificate instructions, and "Da li je korištenje MI besplatno i ko
          # vodi platformu?" with the registration menu. Both facts are already
          # decided and written down; neither is a read.
          # Deliberately NOT the vocative "Milice": a citizen who opens with her
          # name has not made her the subject, and "Milice, da li se parking
          # naplaćuje?" is a parking question.
          PLATFORM_SUBJECT = /(?:platform\w*|aplikacij\w*|ovaj[ ]sajt|ova[ ]stranic\w*|ovu[ ]stranic\w*
                               |mi[ ]pre[ ]d[ ]uzimamo|koristenje[ ]mi\b|koriscenje[ ]mi\b)/x
          OPERATOR_CUE = /(?:\bko[ ](?:vodi|stoji[ ]iza|je[ ]iza|upravlja|je[ ]vlasnik|je[ ]osnovao|je[ ]osnovala
                            |je[ ]napravio|je[ ]napravila|pravi|gradi|drzi)
                           |\bcij[ae][ ](?:je|su)\b
                           |who[ ](?:runs|owns|operates)|who[ ]is[ ]behind)/x
          FREE_CUE = /(?:besplatn\w*|\bgratis\b|naplac\w*|placa[ ]li|placam[ ]li|kosta[ ]li|ima[ ]li[ ]troskov
                       |\bfree[ ]to[ ]use\b|\bfree\b)/x
          # The repair turn names the subject and asks nothing else:
          # "Ne pitam za parking. Pitam za Lokalnu fondaciju i MI."
          ABOUT_REQUEST = /(?:pitam[ ]za|pitam[ ]o|pitam[ ]te[ ]za|zanima[ ]me|reci[ ]mi[ ]o|govorim[ ]o|pricam[ ]o)/x
          # "Da li je to gradska uprava ili Lokalna fondacija Bijeljina?" — the
          # citizen offers the two candidates and asks which. The answer is the
          # operating organisation, never the municipality's switchboard.
          OPERATOR_CHOICE = /(?:gradsk\w*[ ]uprav\w*|opstin\w*|grad[ ]bijeljin\w*).{0,40}\bili\b.{0,40}fondacij
                             |fondacij.{0,40}\bili\b.{0,40}(?:gradsk\w*[ ]uprav\w*|opstin\w*|grad[ ]bijeljin\w*)/x

          # --- who pays for it --------------------------------------------------
          #
          # "Ko plaća ovo?" returned the parking tariffs, and "Ko finansira
          # ovo?" returned "Za ovo nemam provjeren podatak" sourced to the CITY
          # BUDGET PDF — a denial of a fact the repository publishes. The
          # funders are a grant obligation, so the sentence is the deployment's
          # own reviewed one and this engine never composes it.
          FUNDING_CUE = /(?:\bko[ ](?:ovo[ ]|ovu[ ]|sve[ ]ovo[ ]|to[ ]|je[ ]|vam[ ]|ti[ ])?
                           (?:placa|plati|placaju|finansira|financira|izdrzava|snosi|sponzoris\w*|sponzorir\w*)
                          |(?:cime|iz[ ]cega|odakle|cijim[ ]parama|cijim[ ]novcem)[ ](?:se[ ])?(?:finansira|financira|placa)
                          |\bdonator\w*|\bsponzor\w*|\bfinansijer\w*|\bfinancijer\w*
                          |who[ ](?:pays|funds|finances)|who[ ]is[ ](?:paying|funding|financing))/x
          # A payment question about a city service, a bill or a document fee is
          # not a question about who funds the platform.
          FUNDING_NOT_PLATFORM = /(?:racun\w*|taks\w*|postarin\w*|kazn\w*|parking|parkir\w*|odvoz|smec\w*|kontejner\w*
                                   |\bvod[au]\b|struj\w*|grijanj\w*|kart[au]\b|kartu|prevoz|autobus\w*|komunalij\w*
                                   |clanarin\w*|porez\w*|vrtic\w*|skol\w*)/x

          # --- what Milica knows about the citizen -------------------------------
          #
          # "Da li znaš moje ime ako nisam prijavljen?" got the registration
          # menu twice. The answer is the same whether or not they are signed
          # in, so it needs no read and must not imply one.
          IDENTITY_CUE = /(?:(?:da[ ]li[ ])?(?:znas|znate|vidis|vidite|prepoznajes|prepoznajete)
                            (?:[ ]li)?(?:[ ]ti)?(?:[ ]mi)?[ ](?:moje[ ]ime|ko[ ]sam|kako[ ]se[ ]zovem|moj[ ]nadimak)
                           |kako[ ](?:znas|znate|vidis|vidite)[ ](?:ti[ ])?(?:ko[ ]sam|moje[ ]ime)
                           |do[ ]you[ ]know[ ](?:my[ ]name|who[ ]i[ ]am))/x

          # --- what Milica can send, and what she can change ---------------------
          #
          # "Možeš li mi poslati SMS iz ovog razgovora?" and "Možeš li
          # promijeniti moj broj telefona ovdje?" both got the four-way top
          # menu, twice each. A capability question is not a request: "pošalji
          # mi kod ponovo" stays with the account message chain.
          CHAT_SEND_CUE = /(?:(?:mozes|moze|mozete|umijes|umes|znas)[ ]li(?:[ ]ti)?(?:[ ]mi)?(?:[ ]da)?[ ]
                             (?:posalj\w*|salj\w*|poslati|slati|napisati|javis|javiti)
                            |da[ ]li(?:[ ]mi)?[ ](?:mozes|moze|mozete)(?:[ ]da)?[ ](?:posalj\w*|poslati|slati)
                            |mozes[ ]li[ ]mi[ ]poslati
                            |can[ ]you[ ](?:send|text)|are[ ]you[ ]able[ ]to[ ]send)/x
          CHAT_MESSAGE_OBJECT = /(?:\bsms\b|poruk\w*|viber|whatsapp|\bmejl\w*|\be[ ]mail\w*|\bmail\b
                                  |obavjestenj\w*|obavestenj\w*|\bkod\b)/x
          PHONE_CHANGE_ACTION = /(?:promijen\w*|promjen\w*|promen\w*|mijenj\w*|menj\w*|izmijen\w*|izmjen\w*|izmen\w*
                                  |zamijen\w*|zamjen\w*|zamen\w*|\bchange\b|\bupdate\b|\breplace\b)/x
          PHONE_CHANGE_OBJECT = /(?:broj[ ]telefona|telefonsk\w*[ ]broj|\btelefon\w*|mobitel\w*|mobiln\w*|phone[ ]number)/x
          # A message that did not arrive is the RESEND explanation, which the
          # account message chain already owns and answers with the pending
          # page. Neither card above may take one of those turns off it.
          RESEND_REQUEST = /(?:ponovo|opet|jos[ ]jednom
                             |ni(?:je|su)(?:[ ]mi)?[ ](?:stig\w*|dosl\w*|dosao|dosla)
                             |nis[ai]m(?:[ ]jos)?[ ](?:dobio|dobila|primio|primila)
                             |ne[ ]dobijam|nema[ ]poruke|novi[ ]kod|resend|\bagain\b)/x

          # --- where a proposal is submitted --------------------------------------
          #
          # "Gdje da predam prijedlog?" returned 1.298 characters of the
          # foundation's partner profile — including its published donation
          # account and IBAN. The account number is not a leak; answering a
          # PROPOSAL question with a payment instruction is the defect.
          PROPOSAL_WORD = /(?:prijedlog\w*|prijedloz\w*|predlog\w*|predloz\w*|ide[ja]\w*|inicijativ\w*|proposal\w*)/x
          PROPOSAL_SUBMIT = /(?:(?:gdje|gde)(?:[ ]da)?[ ](?:predam|predati|posaljem|poslati|ostavim|unesem|upisem|napisem|prijavim|objavim)
                              |(?:gdje|gde)(?:[ ]se)?[ ](?:predaje|salje|podnosi|ostavlja|upisuje|prijavljuje)
                              |kako(?:[ ]da)?[ ](?:predam|podnesem|posaljem|prijavim|objavim|predlozim|dam)
                              |(?:hocu|zelim|mogu[ ]li|htio[ ]bih|htjela[ ]bih)(?:[ ]da)?[ ](?:predam|posaljem|podnesem|predlozim|prijavim)
                              |where(?:[ ]do[ ]i)?[ ]submit|how(?:[ ]do[ ]i)?[ ]submit)/x

          # THE ORDER IS THE POLICY, and reading this list top to bottom is
          # reading it. Each entry is [predicate, card], where a Symbol in the
          # card slot is a facet chooser rather than a fixed card. The three
          # invariants come first, then the campaign facts, then what Milica
          # herself can do, then what the platform is and who stands behind it
          # — the general "who are you" card stays last, so every specific
          # question is answered as itself.
          SELECTION = [
            [:feedback_controls?, FEEDBACK_CONTROLS],
            [:feedback_meaning?, :feedback_card],
            [:vote_without_points?, VOTE_WITHOUT_POINTS],
            [:vote_integrity?, VOTE_INTEGRITY],
            [:privacy?, PRIVACY],
            [:identity?, IDENTITY],
            [:launch_policy?, :launch_card],
            [:race?, :race_card],
            [:phone_change?, PHONE_CHANGE],
            [:chat_messaging?, CHAT_MESSAGING],
            [:proposal_available?, PROPOSAL_ROUTE],
            [:funding_available?, FUNDING],
            [:foundation_contact?, :foundation_card],
            [:platform_operator?, PLATFORM_OPERATOR],
            [:newcomer?, NEWCOMER]
          ].freeze

          # Cards whose copy needs more than the public rules page. Everything
          # not named here renders from its own key with that one URL.
          RENDERERS = {
            "civic_feedback" => :feedback_answer,
            "civic_feedback_controls" => :feedback_controls_answer,
            "civic_privacy" => :privacy_answer,
            "civic_newcomer" => :operating_name_answer,
            "civic_platform_operator" => :operating_name_answer,
            "civic_funding" => :funding_answer,
            "civic_identity" => :identity_answer,
            "civic_chat_messaging" => :plain_answer,
            "civic_phone_change" => :phone_change_answer,
            "civic_proposal_route" => :proposal_answer,
            "race_overview" => :race_answer,
            "foundation_contact" => :foundation_answer,
            "foundation_phone_unknown" => :foundation_answer
          }.freeze

          module_function

          # The card this utterance asks for, or nil.
          #
          # SELECTION IS ALSO A PRECEDENCE SIGNAL, not only a lookup:
          # AnswerContinuation declines a follow-up the moment a cold card
          # claims the turn ("an explicit new subject keeps precedence"). So a
          # card that quotes a DEPLOYMENT fact the host has not supplied must
          # not claim the turn here either — selecting it and then declining at
          # render time would silence the follow-up machinery and answer
          # nothing. The two such cards check their fact below; every other
          # card needs only copy, and the stage still re-checks that.
          def card(text)
            return unless text.is_a?(String)

            stripped = text.strip
            return unless stripped.length.between?(1, MAX_LENGTH)

            query = Decidim::Bih::Text.fold(stripped)
            return if query.empty?
            # A leading rating label introduces a correction; punctuation is optional.
            return if Decidim::Bih::Transliterator.to_latin(stripped).match?(/\A(?:(?:to|ovo)\s+)?(?:nije\s+korisno|korisno)(?:\s*[:,;.—–-]\s*\S|\s+(?:pitam|pitao|treba|ne\s+(?:pitam|trebam|zelim)|mislio|mislila)\b)/i)

            card_for(query)
          end

          def card_for(query)
            _, card = SELECTION.find { |predicate, _| send(predicate, query) }
            return if card.nil?

            card.is_a?(Card) ? card : send(card, query)
          end

          def vote_without_points?(query)
            /\bglas\w*\b.*\bbez\s+(?:bodov\w*|poen\w*)\b/.match?(query)
          end

          def vote_integrity?(query)
            return false if query.match?(/(?:mislio|mislila|zelim|hocu).{0,25}donir\w*.{0,30}ne\s+glas/)
            return true if PROPOSAL_PROMINENCE.match?(query)
            return false unless INFLUENCE_SUBJECT.match?(query)
            return true if INFLUENCE_CLAIM.match?(query)

            DECIDING.match?(query) && !DECIDER_IDENTITY.match?(query)
          end

          def privacy?(query)
            return false if REPORT_PRIVACY.match?(query) || AccountQuestion.direct_phone_observation?(query)
            return true if PRIVACY_POLICY.match?(query)

            MY_DATA.match?(query) && DATA_ACTION.match?(query)
          end

          # A launch-policy question, as opposed to a question about a public
          # call that merely contains the substring "poziv".
          def launch_policy?(query)
            return false if PUBLIC_CALL_TERM.match?(query)
            return false unless LAUNCH_ANCHOR.match?(query)

            LAUNCH_COST.match?(query) || LAUNCH_CONFIRM.match?(query) ||
              LAUNCH_DEADLINE_CUE.match?(query) || LAUNCH_ELIGIBILITY_CUE.match?(query)
          end

          # Facet order is deliberate. Cost first, because "da li se za
          # pozivnicu oduzima 20 bodova" also carries a confirmation-shaped word
          # in some phrasings and the points answer is what settles it. Then
          # eligibility, because "bez potvrđenog telefona" carries the "potvrd"
          # stem while asking who qualifies, not whether an unconfirmed
          # invitation lapses.
          def launch_card(query)
            return LAUNCH_NOT_SPENT if LAUNCH_COST.match?(query)
            return LAUNCH_ELIGIBILITY if LAUNCH_ELIGIBILITY_CUE.match?(query)
            return LAUNCH_CONFIRMATION if LAUNCH_CONFIRM.match?(query)

            LAUNCH_DEADLINE_CUE.match?(query) ? LAUNCH_DEADLINE : LAUNCH_ELIGIBILITY
          end

          def race?(query)
            return false if PUBLIC_CALL_TERM.match?(query)
            return true if RACE_ANCHOR.match?(query) && RACE_CONTEXT.match?(query)

            league_race?(query)
          end

          # "Koliko dobija pobjednik svake lige?" — the race named by its two
          # leagues rather than by the word "trka". A league alone is not
          # enough: the citizen must also be asking who wins or what the winner
          # gets, and no sports word may be in the sentence.
          def league_race?(query)
            return false unless LEAGUE_ANCHOR.match?(query)
            return false if SPORTS_TERM.match?(query)

            RACE_WINNER_CUE.match?(query) || RACE_PRIZE_CUE.match?(query)
          end

          def race_card(query)
            RACE_PRIZE_CUE.match?(query) ? RACE_PRIZE : RACE_OVERVIEW
          end

          def foundation_contact?(query)
            FOUNDATION_NAME.match?(query) && FOUNDATION_CONTACT_CUE.match?(query)
          end

          def foundation_card(query)
            FOUNDATION_PHONE_CUE.match?(query) ? FOUNDATION_PHONE : FOUNDATION_CONTACT
          end

          # Who runs the platform, and whether it costs anything. Both facts
          # live in one card because the corpus asks them in one sentence.
          def platform_operator?(query)
            return false if PUBLIC_CALL_TERM.match?(query)
            return true if OPERATOR_CHOICE.match?(query)

            operator_named?(query) || free_use_question?(query) || about_the_operator?(query)
          end

          def operator_named?(query)
            OPERATOR_CUE.match?(query) && (PLATFORM_SUBJECT.match?(query) || FOUNDATION_NAME.match?(query))
          end

          # A city fee named next to the platform is still a city fee.
          def free_use_question?(query)
            FREE_CUE.match?(query) && PLATFORM_SUBJECT.match?(query) && !FUNDING_NOT_PLATFORM.match?(query)
          end

          def about_the_operator?(query)
            ABOUT_REQUEST.match?(query) && FOUNDATION_NAME.match?(query)
          end

          def newcomer?(query) = NEWCOMER_QUESTION.match?(query)

          # Who PAYS is a different question from who runs it, and it is the
          # one with a grant obligation attached. The city-service guard is the
          # WEAKER test on purpose: naming the platform settles it outright, so
          # a repair that negates the wrong topic ("Ne pitam za parking. Pitam
          # ... ko je finansira.") is still a funding question — the negated
          # word is in the sentence precisely because the citizen rejected it.
          def funding?(query)
            return false unless FUNDING_CUE.match?(query)
            return true if PLATFORM_SUBJECT.match?(query)

            !FUNDING_NOT_PLATFORM.match?(query)
          end

          # Questions ABOUT the rating control are public help. A correction
          # that merely mentions a rating must reach the active task instead.
          # Help ABOUT a missing rating control, never a vote or correction.
          # An optional complaint may precede the actual control question.
          FEEDBACK_SUBJECT = /\b(?:nije\s+)?korisno\b|nekorisn\w*|ocjen\w*|ocen\w*|rating|helpful/
          FEEDBACK_QUESTION = /(?:sta\s+(?:znaci|radi|se)|cemu|kako|zasto|ko\s+vidi|da\s+li|je\s+li|mogu\s+li|dobijam\s+li|ako\s+(?:klik|napis)|mislim|pitam|objasni|razlikuj|what\s+(?:is|does)|how\s+do|who\s+sees)/
          FEEDBACK_FACETS = %w(privacy points change typed deletion report account target repair description).to_h do |facet|
            [facet, Card.new(name: "civic_feedback_#{facet}", answer_intent: "help")]
          end.freeze

          def feedback_controls?(query)
            return false if mixed_feedback_question?(query) || external_rating_subject?(query)

            FEEDBACK_SUBJECT.match?(query) &&
              query.match?(/(?:nema|nemam|ne\s+vidim|nedostaje|missing|cannot\s+see).{0,45}(?:dugme\w*|dugmad|opcija|ocjen\w*|ocen\w*|button|control)/)
          end

          # Subject-free descriptions require a retained feedback card.
          def feedback_description_follow_up?(query)
            query.match?(/\A(?:a\s+)?(?:mogu\s+li|smijem\s+li)(?:\s+ti)?(?:\s+samo)?\s+(?:napisati|objasniti|opisati)\s+
                          (?:sta|sto)\s+(?:je\s+)?(?:pogresno|netacno|bilo\s+pogresno|nije\s+u\s+redu)\z/x) ||
              query.match?(/\Acan\s+i(?:\s+just)?\s+(?:write|explain|describe)\s+what\s+(?:is|was)\s+wrong\z/)
          end

          def mixed_feedback_question?(query)
            query.match?(/\b(?:i|pa|a|and|then)\s+(?:kada|kad|gdje|gde|koliko|prijavi|posalji|when|where|submit)\b/)
          end

          def external_rating_subject?(query)
            /(?:skolsk\w*|matematik\w*|profesor\w*|nastavnik\w*|ucenik\w*|predmet\w*|ispit\w*|restoran\w*)/.match?(query) ||
              (/gradsk\w*\s+sluzb\w*/.match?(query) && !/(?:milic|tvoj\w*\s+odgovor|korisno)/.match?(query))
          end

          def feedback_meaning?(query)
            return false if mixed_feedback_question?(query)

            return true if query.match?(/kako\s+(?:da\s+)?(?:popravim|ispravim).{0,30}(?:netacan|pogresan)\s+odgovor/)
            # A rating label preceding a real correction is not a help question.
            return false if query.match?(/\A(?:nije\s+korisno|korisno)(?:\s+hvala)?\s+(?:kako|kada|kad|gdje|gde|pitao|pitam|treba|ne\s+zelim)/)
            return false if query.match?(/(?:oznacio|oznacila).{0,45}\bjer\b/)
            return false unless FEEDBACK_SUBJECT.match?(query)
            return false if external_rating_subject?(query)

            FEEDBACK_QUESTION.match?(query) ||
              query.match?(/(?:ocjenjujem|ocenjujem).{0,45}(?:milic|tvoj\w*\s+odgovor)/) ||
              query.match?(/\Aoznaci[ol]\w*\s+sam\s+odgovor\s+nekorisn/)
          end

          def feedback_card(query)
            feedback_facet_card(query) || FEEDBACK
          end

          # Called only with retained feedback context. A new substantive task
          # must not be captured just because the preceding reply explained a button.
          def feedback_follow_up_card(query)
            return FEEDBACK_FACETS.fetch("repair") if query == "ne trazim registraciju"
            return FEEDBACK_FACETS.fetch("description") if feedback_description_follow_up?(query)
            return unless query.match?(/\A(?:a\s+)?(?:da\s+li|sta\s+se|ne\s+izmisljaj\s+dugme|moze\s+li\s+tekstualna|razlikuj\s+poruku|odgovor\s+moze|objasni\s+samo|mislim|ne\s+ocjenjujem)/)
            return unless query.match?(/(?:tim[ei]|\bto\b|dugme|tekstualn|poruku\s+od|odgovor|ocjen|ocen|privatnost)/)

            feedback_facet_card(query)
          end

          def feedback_facet_card(query)
            facet = if query.match?(/(?:ko\s+vidi|privatnost|javn\w*|pregled|osoblje|nalogom)/)
                      "privacy"
                    elsif query.match?(/bodov|poen/)
                      "points"
                    elsif query.match?(/promijen|promen|mijenj|menj|izmisljaj\s+dugme/)
                      "change"
                    elsif query.match?(/napis|tekstualn|rijec|rec\b|razlikuj\s+poruku|poruk\w*\s+od\s+klik/)
                      "typed"
                    elsif query.match?(/bris|izbris|uklanja/)
                      "deletion"
                    elsif query.match?(/prijav\w*.{0,20}gradu|salje\s+prijav|rijes|rjesen|resen|komunaln/)
                      "report"
                    elsif query.match?(/otvara\s+nalog|registracij|automatski.{0,20}nalog/)
                      "account"
                    elsif query.match?(/popravim|ispravim|netacan|pogresan/)
                      "repair"
                    elsif query.match?(/ocjenjuj|ocenjuj|oznacio\s+sam\s+odgovor|sta\s+se|sluzb|mislim\s+na\s+korisno/)
                      "target"
                    end
            FEEDBACK_FACETS[facet]
          end

          def identity?(query) = IDENTITY_CUE.match?(query)

          def chat_messaging?(query)
            return false if RESEND_REQUEST.match?(query)

            CHAT_SEND_CUE.match?(query) && CHAT_MESSAGE_OBJECT.match?(query)
          end

          def phone_change?(query)
            return false if RESEND_REQUEST.match?(query)

            PHONE_CHANGE_ACTION.match?(query) && PHONE_CHANGE_OBJECT.match?(query)
          end

          def proposal_route?(query)
            PROPOSAL_WORD.match?(query) && PROPOSAL_SUBMIT.match?(query)
          end

          # The two cards that quote a fact only the host has. See the note on
          # +card+: a card that cannot render must not claim the turn either.
          def proposal_available?(query) = proposal_route?(query) && configured?(:proposal_path)

          def funding_available?(query) = funding?(query) && configured?(:public_funding_statement)

          # The rendered copy for a card, or nil when the host has not supplied a
          # fact the card needs (the foundation's public contact e-mail). Never
          # guesses: a card with no copy declines and the turn continues.
          #
          # A card not named in RENDERERS is one reviewed sentence carrying the
          # public rules page, which is what most of them are.
          def answer(card, locale:, brief: false)
            return t("civic_vote_integrity_brief", locale:, url: rules_url) if brief && card == VOTE_INTEGRITY
            if card.name.start_with?("civic_feedback_") && card.name != "civic_feedback_controls"
              return t(card.name, locale:)
            end

            renderer = RENDERERS[card.name]
            return t(card.name, locale:, url: rules_url) unless renderer

            send(renderer, card, locale:)
          end

          def operating_name_answer(card, locale:) = t(card.name, locale:, name: support_name)

          def feedback_controls_answer(_card, locale:)
            I18n.t("decidim.bih.concierge.feedback_help.missing_controls", locale:)
          end

          def feedback_answer(_card, locale:)
            I18n.t("decidim.bih.concierge.feedback_help.answer", locale:)
          end

          def plain_answer(card, locale:) = t(card.name, locale:)

          def identity_answer(card, locale:) = t(card.name, locale:, url: sign_in_url)

          def race_answer(card, locale:) = t(card.name, locale:, url: race_url)

          # WHO PAYS is this deployment's own reviewed sentence, quoted whole.
          # The engine never composes, abbreviates or guesses a funder credit:
          # with nothing configured the card declines and the turn continues,
          # which is the only honest alternative to naming the wrong funder.
          def funding_answer(card, locale:)
            statement = funding_statement(locale:)
            return if statement.nil?

            t(card.name, locale:, statement:)
          end

          # The host's destination for a new proposal. Declines when unset
          # rather than pointing at a page that may not accept one.
          def proposal_answer(card, locale:)
            url = proposal_url
            return if url.nil?

            t(card.name, locale:, url:)
          end

          # The number can only be changed by the citizen, and once it is
          # confirmed only with the operator's help — so the card needs the
          # published support address and declines without it.
          def phone_change_answer(card, locale:)
            email = support_email
            return if email.nil?

            t(card.name, locale:, email:)
          end

          def privacy_answer(card, locale:)
            email = support_email
            return if email.nil?

            t(card.name, locale:, url: privacy_policy_url, email:, name: support_name)
          end

          # The foundation's own published record, never a municipality contact
          # with a substituted label, and never the operator back-channel stored
          # in a column named "private".
          def foundation_answer(card, locale:)
            email = support_email
            return if email.nil?

            address = present(safe_config(:public_support_address))
            website = present(safe_config(:public_support_website))
            lines = []
            lines << t("foundation_phone_unknown", locale:) if card.name == "foundation_phone_unknown"
            lines << if address && website
                       t("foundation_contact", locale:, name: support_name, address:, email:, url: website)
                     else
                       t("foundation_contact_minimal", locale:, name: support_name, email:)
                     end
            lines << t("foundation_phone_not_city", locale:) if card.name == "foundation_phone_unknown"
            lines.join("\n")
          end

          # Two-to-four supported choices for the newcomer card. Engine-owned
          # routes only: the host's own campaign pages are named in the copy
          # rather than guessed at here.
          def quick_replies(card, locale:)
            return [] unless card.name == "civic_newcomer"

            [
              chip(t("civic_newcomer_chip_report", locale:), engine_path(:new_report_path, "prijave/new")),
              chip(t("civic_newcomer_chip_komsiluk", locale:), engine_path(:komsiluk_board_index_path, "komsiluk-board")),
              chip(t("civic_newcomer_chip_points", locale:), rules_url)
            ].compact
          end

          def chip(label, url)
            return if url.nil? || label.to_s.strip.empty?

            { label:, url: }
          end

          def t(key, locale:, **values)
            I18n.t("decidim.bih.dialogue.#{key}", locale:, **values)
          end

          def present(value)
            text = value.to_s.strip
            text.empty? ? nil : text
          end

          def support_name
            present(safe_config(:public_support_name)) || "MI PRE(D)UZIMAMO!"
          end

          def support_email
            present(safe_config(:public_support_email))
          end

          # Whether the host supplied the fact at all. A configured provider that
          # then fails is an outage, and the render-time nil check covers it.
          def configured?(name) = !safe_config(name).nil?

          def safe_config(name)
            Decidim::Bih.public_send(name)
          rescue StandardError
            nil
          end

          # A String, or a callable the host passes so the sentence is rendered
          # in the citizen's own locale at answer time.
          def funding_statement(locale:)
            configured = safe_config(:public_funding_statement)
            present(configured.respond_to?(:call) ? configured.call(locale:) : configured)
          rescue StandardError
            nil
          end

          # A String, or a callable, because a host that resolves the live
          # proposals component from its database cannot do so at boot.
          def proposal_url
            configured = safe_config(:proposal_path)
            present(configured.respond_to?(:call) ? configured.call : configured)
          rescue StandardError
            nil
          end

          def rules_url = hub_path("zajednistvo?tab=kako")

          def race_url = hub_path("zajednistvo?tab=trka")

          # The engine's own mount, with the literal fallback the standalone
          # unit tests (which never load the host) need.
          def hub_path(suffix)
            Decidim::Bih.public_path(suffix)
          rescue StandardError
            "/biceriseno/#{suffix}"
          end

          def sign_in_url
            Decidim::Core::Engine.routes.url_helpers.new_user_session_path(locale: I18n.locale)
          rescue StandardError
            "/#{I18n.locale}/users/sign_in"
          end

          def privacy_policy_url
            Decidim::Core::Engine.routes.url_helpers.page_path("privacy-policy")
          rescue StandardError
            "/pages/privacy-policy"
          end

          def engine_path(helper, suffix)
            Decidim::Bih::Engine.routes.url_helpers.public_send(helper)
          rescue StandardError
            hub_path(suffix)
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE ordered, registrable list of deterministic reads: a citizen
        # utterance that one of these matchers recognises is answered from a
        # reviewed source without ever asking the model.
        #
        # == Registration point and ordering guarantee
        #
        # +register+ is the single registration point. Routes are evaluated in
        # registration order and the FIRST route that returns a read wins; a
        # route that returns nil lets the next one try. Registration appends by
        # default, so a route added later is evaluated last; pass +before:+ or
        # +after:+ with an existing route name to place it exactly. Registering
        # a name that already exists REPLACES it in place, which keeps the list
        # stable when a file is loaded twice.
        #
        # A route registered from another file only applies once that file is
        # LOADED. Production eager-loads app/services, but the host's test
        # environment does not (config.eager_load is CI-only), so do not rely on
        # autoloading: put the +register+ call at the top level of your file and
        # add one +require_relative+ for it beside the built-ins at the bottom of
        # this file. That is the whole edit — the added line also makes the new
        # route's position in the order explicit and reviewable.
        #
        # The built-in routes at the bottom of this file are registered in
        # exactly the order CivicQuestion#classify evaluated them before this
        # list existed: document, board, earning, pharmacy, invitation,
        # komsiluk, mz_contact. Do not reorder them — the order is behaviour.
        #
        # == Matcher contract
        #
        # A matcher receives (query, text): +query+ is the folded utterance and
        # +text+ the citizen's original. The caller bounds the length before
        # folding (CivicQuestion refuses anything over 160 characters). A
        # matcher returns nil, or a proposed typed read
        # ({ action:, topic:, entities: }) — selection only: the normal task,
        # scope and permission guards still run afterwards.
        module DeterministicRoutes
          # The three whole-utterance patterns below are /x only so they fit on
          # the page: every literal space is spelled [ ], so the matched
          # language is unchanged from the single-line form they replaced.
          DOCUMENT = /\A(?:kako[ ](?:da[ ]|mogu[ ])?(?:pribavim|dobijem|izvadim|izvaditi)|
                        gdje[ ](?:mogu[ ])?(?:dobiti|izvaditi)|gde[ ](?:mogu[ ])?(?:dobiti|izvaditi))
                       [ ](?:rodni[ ]list|izvod[ ]iz[ ]maticne[ ]knjige[ ]rodjenih)\z/x
          BOARD = /\A(?:ima[ ]li[ ](?:nekih[ ])?(?:obavjestenja|obavjestanja|obavijesti|objava)|
                       (?:prikazi|pokazi|procitaj)(?:[ ]mi)?[ ](?:obavjestenja|obavijesti|objave))
                      [ ](?:na[ ]tabli|na[ ]ploci)[ ](?:mog|mojeg|moga)[ ](?:komsiluka|susjedstva)\z/x
          BOARD_POSTS = /\A(?:zanimaju[ ]me|zelim[ ](?:vidjeti|videti|procitati)|prikazi(?:[ ]mi)?|pokazi(?:[ ]mi)?)
                        [ ]objave[ ](?:komsija|clanova)[ ](?:na[ ]platformi|na[ ]tabli[ ]komsiluka)
                        (?:[ ]ne[ ](?:vijesti|vesti)[ ]sa[ ]gradskog[ ]sajta)?\z/x
          MZ_CONTACT = /\A(?:ko[ ]je[ ](?:predsjednik|predsednik)|
                            (?:koji[ ]je[ ]|daj[ ]mi[ ])?(?:kontakt|telefon)(?:[ ]predsjednika|[ ]predsednika)?)
                           [ ](?:moje[ ]|mojeg[ ]|moju[ ])?(?:mz|mjesne[ ]zajednice|mesne[ ]zajednice)
                           (?:[ ](?<area>[a-z][a-z -]{0,100}))?\z/x

          # "How do I earn points" — the earning rules, not the citizen's own
          # balance. Whole-utterance matches on folded text; "moji bodovi" and
          # "koliko imam bodova" deliberately fall through to the balance path.
          # Every literal space is spelled [ ], as DOCUMENT and MZ_CONTACT in
          # this file already do. /x drops real spaces, so each multi-word
          # alternative written with one was unreachable: "a "/"pa ",
          # "na koji nacin", "kojim putem", "mogu da", "dobre volje",
          # "na platformi", "kod vas", "kod tebe" and "kod milice" were all
          # spelled out here and none of them could ever match.
          EARN = /\A(?:(?:a[ ]|pa[ ])?(?:kako|gdje|gde|na[ ]koji[ ]nacin|sta|sto|cime|kojim[ ]putem)\s+)?
                  (?:(?:se|da|mogu|mogu[ ]da|bih|bi|cu|mi|ja|ovdje|ovde|tu)\s+)*
                  (?:zarad|zaradj|osvoj|osvaj|dobij|dobiv|skup|sakup|steci|stek|stic|prikup|donos|donese|zasluz)\w*\s+
                  (?:(?:vise|jos|neke|nove|te|ove|svoje|moje|prve)\s+)?
                  (?:bodov\w*|poen\w*|bod)
                  (?:\s+(?:zajednistva|dobre[ ]volje|na[ ]platformi|ovdje|ovde|kod[ ]vas|kod[ ]tebe|komsija|kod[ ]milice))*\z/x
          EARN_VALUE = /\Akoliko (?:bodova|poena|bodova zajednistva) (?:nosi|donosi|dobijam|dobijem|se dobija|se dobije|vrijedi|vredi|daje)\b/
          EARN_PHRASES = [
            "kako se dobijaju bodovi", "kako funkcionisu bodovi", "kako rade bodovi", "sta donosi bodove",
            "kako do bodova", "kako doci do bodova", "kako se skupljaju bodovi", "kako se osvajaju bodovi",
            "kako se zaradjuju bodovi", "kako se boduje", "sta se boduje", "sta nosi bodove", "za sta se dobijaju bodovi",
            "za sta dobijam bodove", "kako bodovanje radi", "kako radi bodovanje", "pravila bodovanja", "kako se racunaju bodovi"
          ].freeze

          # Own-state questions: the citizen's launch invitation and chosen
          # komšiluk. Whole-utterance matches on folded text, so Latin and
          # Cyrillic spellings share one pattern and "šta ima u mom komšiluku"
          # (a board read) or "imam pozivnicu" (a statement) never match. The
          # Responder answers them read-only for the resolved, scope-matched
          # user; an anonymous chat gets the sign-in hand-off instead.
          # "molim te" spells its space [ ] because this pattern is not /x but
          # is interpolated by .source into INVITATION and KOMSILUK, which are:
          # a real space survives here and is dropped there.
          OWN_STATE_PREFIX = /(?:(?:milica|milice|komsinice|komsinica|hej|ej|molim[ ]te|molim|a|pa|i|e)\s+)*/
          LAUNCH_EVENT = /(?:17\s*9|17\s+septemb\w*|lansiranj\w*(?:\s+platforme)?|dogadjaj|otvaranje)/
          INVITATION = /\A#{OWN_STATE_PREFIX.source}(?:
            (?:jesam\s+li|da\s+li\s+sam|jel\s+sam|jeli\s+sam|dal\s+sam)(?:\s+ja)?\s+pozvan[ai]?(?:\s+(?:na|za)\s+#{LAUNCH_EVENT.source})?
            |(?:(?:da\s+li|jel|jeli|dal|je\s+li)\s+imam|imam\s+li)(?:\s+ja)?\s+(?:pozivnicu|rezervaciju)(?:\s+za\s+#{LAUNCH_EVENT.source})?
            |(?:jesam\s+li|da\s+li\s+sam|jel\s+sam|jeli\s+sam|dal\s+sam)(?:\s+ja)?\s+dobi[ol][ao]?\s+pozivnicu(?:\s+za\s+#{LAUNCH_EVENT.source})?
            |(?:da\s+li|jel|jeli|dal|je\s+li)\s+(?:mi\s+je|mi|je)\s+(?:stigla|dosla)\s+pozivnica(?:\s+za\s+#{LAUNCH_EVENT.source})?
            |(?:gdje|gde)\s+(?:je|mi\s+je)\s+(?:moja\s+)?pozivnica
            |(?:koji\s+je\s+)?moj\s+(?:broj\s+rezervacije|kod\s+za\s+ulaz|ulazni\s+kod)
            |(?:status|stanje)\s+(?:moje\s+)?pozivnice
            |moja\s+(?:pozivnica|rezervacija)(?:\s+za\s+#{LAUNCH_EVENT.source})?
            |broj\s+(?:moje\s+)?rezervacije
            |kada?\s+je\s+lansiranje(?:\s+platforme)?
          )\z/x
          KOMSILUK_WORD = /(?:komsiluk[au]?|susjedstv[oau]|mz|m[j]?esn(?:a\s+zajednica|u\s+zajednicu|oj\s+zajednici))/
          KOMSILUK = /\A#{OWN_STATE_PREFIX.source}(?:
            (?:koji|koja|koje)\s+(?:je\s+moj[a]?|mi\s+je|je\s+moja)\s+#{KOMSILUK_WORD.source}(?:\s+(?:sad|sada|trenutno))?
            |u\s+(?:kom|kojem|kojoj)\s+(?:sam(?:\s+ja)?\s+#{KOMSILUK_WORD.source}|#{KOMSILUK_WORD.source}\s+sam(?:\s+ja)?)
            |(?:gdje|gde)\s+sam(?:\s+ja)?\s+(?:prijavljen[a]?|registrovan[a]?|upisan[a]?)(?:\s+(?:kao\s+komsija|u\s+komsiluk))?
            |(?:koji|koju|koja)\s+(?:komsiluk|mz|mjesnu\s+zajednicu|mesnu\s+zajednicu)\s+sam\s+(?:izabrao|izabrala|odabrao|odabrala)
            |(?:koji|koju)\s+sam\s+(?:komsiluk|mz)\s+(?:izabrao|izabrala|odabrao|odabrala)
            |(?:jesam\s+li|da\s+li\s+sam|jel\s+sam|dal\s+sam)(?:\s+ja)?\s+(?:izabra|odabra)(?:o|la)\s+(?:svoj\s+|moj\s+)?(?:komsiluk|mz|m[j]?esnu\s+zajednicu)
            |moj\s+komsiluk|moja\s+(?:mz|mjesna\s+zajednica|mesna\s+zajednica)
          )\z/x

          # Three more own-state questions, and one public one. Each is a
          # SEPARATE question that the account family answered with the same
          # sentence: on 14.09, signed in, "Da li sam verifikovan?",
          # "Kako se zovem?" and "Gdje je moj link za pozivanje komšija?" all
          # returned the identical 90-character registration menu, while
          # "Koliko sam ljudi pozvao?" and "Da li mi je broj telefona
          # potvrđen?" both returned the identical "ovaj korak je već
          # završen". Five questions, two answers, none of them the answer.
          #
          # They are own-state and not account-form questions: the account
          # menu can only ever offer a JOURNEY, and none of these asks for
          # one. Whole-utterance matches on folded text, exactly like
          # INVITATION and KOMSILUK above, and selection only — the Responder
          # still resolves the user, checks the conversation's trusted scope
          # and reads nothing the citizen may not read.
          VERIFIED_WORD = /(?:verifikovan[aio]?|verificiran[aio]?|potvrdjen[aio]?)/
          ASK_AM_I = /(?:jesam\s+li|da\s+li\s+sam|jel\s+sam|jeli\s+sam|dal\s+sam)/
          ASK_IS_IT = /(?:da\s+li|jel|jeli|dal|je\s+li)/
          ACCOUNT_THING = /(?:nalog|racun|profil)/
          PHONE_THING = /(?:broj\s+telefona|broj|telefon)/
          VERIFICATION_STATE = /\A#{OWN_STATE_PREFIX.source}(?:
            #{ASK_AM_I.source}(?:\s+ja)?\s+#{VERIFIED_WORD.source}
            |#{ASK_IS_IT.source}\s+(?:mi\s+je|je|mi)\s+(?:moj\s+|moja\s+)?(?:#{PHONE_THING.source}|#{ACCOUNT_THING.source}|adresa)
              \s+(?:vec\s+)?#{VERIFIED_WORD.source}
            |#{ASK_AM_I.source}(?:\s+ja)?\s+(?:potvrdio|potvrdila)\s+(?:svoj\s+|moj\s+)?(?:#{PHONE_THING.source}|#{ACCOUNT_THING.source})
            |(?:koji\s+je\s+|kakav\s+je\s+)?(?:status|stanje)\s+(?:moje\s+|mojeg\s+)?(?:verifikacije|potvrde|verifikacija)
            |(?:jesam\s+li|da\s+li\s+sam)\s+(?:vec\s+)?(?:prosao|prosla)\s+verifikaciju
            |am\s+i\s+verified|is\s+my\s+(?:phone|number|account)\s+verified
          )\z/x

          # "Koliko sam ljudi pozvao?" — the citizen's own referral count.
          # The deployed +goodwill_referral+ route needs a POINTS word in the
          # sentence, so neither of the two most natural referral questions
          # could ever reach it; this one asks for a COUNT, not a rule.
          INVITED_VERB = /(?:pozvao|pozvala|registrovao|registrovala|doveo|dovela)/
          INVITED_WHO = /(?:ljudi|komsija|komsije|susjeda|susjede|prijatelja|prijatelje|osoba|njih|clanova)/
          REFERRAL_COUNT = /\A#{OWN_STATE_PREFIX.source}(?:
            koliko\s+(?:sam\s+)?(?:ja\s+)?(?:#{INVITED_WHO.source}\s+)?(?:sam\s+)?#{INVITED_VERB.source}(?:\s+#{INVITED_WHO.source})?
            |koliko\s+(?:mojih\s+)?(?:poziva|pozivnica|preporuka)\s+(?:je\s+)?(?:uspjelo|uspjesno|priznato|placeno|prihvaceno)
            |(?:koji\s+je\s+|kakav\s+je\s+)?(?:broj|spisak)\s+(?:mojih\s+)?(?:poziva|preporuka)
            |how\s+many\s+(?:people|neighbours|neighbors|friends)\s+(?:have\s+)?i\s+invited
          )\z/x

          # "Kako se zovem?" — who the citizen is, to their own signed-in
          # session. A privacy question about an ANONYMOUS session ("Da li
          # znaš moje ime ako nisam prijavljen?") is a different question and
          # is not matched here: this is whole-utterance, so a sentence
          # carrying that condition never reaches it.
          IDENTITY = /\A#{OWN_STATE_PREFIX.source}(?:
            kako\s+se\s+(?:ja\s+)?zovem
            |(?:koje|sta)\s+(?:je\s+)?(?:moje\s+ime|mi\s+je\s+ime)
            |(?:znas|znate)\s+li\s+(?:ti\s+)?(?:ko\s+sam(?:\s+ja)?|moje\s+ime|kako\s+se\s+zovem)
            |ko\s+sam\s+ja
            |(?:koji|koje)\s+je\s+moj\s+(?:nadimak|korisnicko\s+ime|username)
            |moj\s+nadimak
            |what\s+is\s+my\s+name|do\s+you\s+know\s+(?:my\s+name|who\s+i\s+am)
          )\z/x

          # "Gdje je moj link za pozivanje komšija?" — PUBLIC. The personal
          # link and its printable QR live on a page anyone can open, so this
          # needs no ledger, no identity and no authorization; naming the page
          # is the whole answer. It is grouped with the own-state questions
          # because it is the one the corpus asks in the same breath.
          INVITE_LINK_THING = /(?:link|linka|link[au]|kod|koda|kodu|qr|qr\s+kod)/
          INVITE_PURPOSE = /(?:pozivanje(?:\s+komsija|\s+prijatelja|\s+susjeda)?|poziv|pozive|pozivnice|preporuku|preporuke|dijeljenje)/
          INVITE_LINK = /\A#{OWN_STATE_PREFIX.source}(?:
            (?:gdje|gde)\s+(?:je|mi\s+je|mogu\s+(?:da\s+)?(?:nadjem|nadem|vidim|pronadjem))\s+(?:moj\s+|moja\s+)?
              #{INVITE_LINK_THING.source}(?:\s+za\s+#{INVITE_PURPOSE.source})?
            |(?:koji|koja)\s+je\s+moj\s+#{INVITE_LINK_THING.source}\s+za\s+#{INVITE_PURPOSE.source}
            |moj\s+#{INVITE_LINK_THING.source}\s+za\s+#{INVITE_PURPOSE.source}
            |(?:kako|gdje|gde)\s+(?:da\s+)?(?:pozovem|pozivam|zovem)\s+(?:svoje\s+|moje\s+)?#{INVITED_WHO.source}
            |where\s+is\s+my\s+(?:invite|invitation|referral)\s+link
          )\z/x

          # Pharmacy and health-centre questions. The model spent the whole
          # understanding budget on "ima li dezurna apoteka nocas" in production
          # (2026-09-13); the reviewed health card needs no slot, so the read is
          # selected here and the model is never asked.
          PHARMACY = /\A(?:(?:a|pa|e|hej)\s+)?(?:(?:ima\s+li|da\s+li\s+ima|jel\s+ima|dal\s+ima|gdje\s+je|gde\s+je|koja\s+je|koja|gdje|gde|ima)\s+)?
                       (?:(?:neka|najbliza)\s+)?(?:dezurn\w*\s+)?(?:apotek\w*|ljekarn\w*|dom\s+zdravlja|hitn\w*\s+pomoc\w*)
                       (?:\s+(?:radi|otvoren\w*|dezura|dezurna))?
                       (?:\s+(?:u\s+)?(?:nocas|veceras|danas|sada|sad|sutra|vikend\w*|nedjelj\w*|
                                       nedelj\w*|subot\w*|praznik\w*|noc\w*|bijeljin\w*|gradu|centru))*
                       \s*[?.!]*\z/x

          Route = Data.define(:name, :matcher)

          class << self
            # The registration point. See the ordering guarantee above.
            def register(name, before: nil, after: nil, &matcher)
              raise ArgumentError, "Route name required" unless name.is_a?(String) && !name.empty?
              raise ArgumentError, "Route matcher required" unless matcher

              route = Route.new(name:, matcher:)
              existing = routes.index { |candidate| candidate.name == name }
              return routes[existing] = route if existing

              routes.insert(position(before:, after:), route)
              route
            end

            def routes
              @routes ||= []
            end

            def route_names
              routes.map(&:name)
            end

            # The first route that recognises this utterance, or nil.
            def match(query, text)
              routes.each do |route|
                read = route.matcher.call(query, text)
                return read if read
              end
              nil
            end

            # One of OWN_STATE_CATEGORIES or nil — the own-state category
            # alone, for callers that need the label without proposing a read.
            #
            # THE ORDER IS THE POLICY, and the two original categories keep
            # their place at the top so nothing they answer today can be
            # claimed by a newer one.
            OWN_STATE_CATEGORIES = %w(invitation komsiluk verification referrals identity invite_link).freeze
            # The one category answered from PUBLIC copy: the invite page is
            # open to anyone, so it is answered without resolving a user.
            PUBLIC_OWN_STATE_CATEGORIES = %w(invite_link).freeze

            def own_state_category(query)
              return "invitation" if INVITATION.match?(query)
              return "komsiluk" if KOMSILUK.match?(query)
              return "verification" if VERIFICATION_STATE.match?(query)
              return "referrals" if REFERRAL_COUNT.match?(query)
              return "identity" if IDENTITY.match?(query)
              return "invite_link" if INVITE_LINK.match?(query)

              nil
            end

            def earning_query?(query)
              EARN.match?(query) || EARN_VALUE.match?(query) || EARN_PHRASES.include?(query)
            end

            private

            def position(before:, after:)
              anchor = before || after
              return routes.length unless anchor

              index = routes.index { |candidate| candidate.name == anchor }
              raise ArgumentError, "Unknown route #{anchor}" unless index

              before ? index : index + 1
            end
          end

          # THE BUILT-IN ROUTES, in the order CivicQuestion evaluated them
          # before extraction. Their bodies are unchanged.
          register("document") do |query, text|
            { action: "ask_information", topic: "city_service", entities: { "query" => text } } if DOCUMENT.match?(query)
          end

          register("board") do |query, text|
            { action: "neighborhood_information", topic: "neighborhood", entities: { "query" => text } } if BOARD.match?(query) || BOARD_POSTS.match?(query)
          end

          register("earning") do |query, text|
            { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "earn" } } if earning_query?(query)
          end

          register("pharmacy") do |query, text|
            { action: "ask_information", topic: "health", entities: { "query" => text } } if PHARMACY.match?(query)
          end

          register("invitation") do |query, text|
            { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "invitation" } } if own_state_category(query) == "invitation"
          end

          register("komsiluk") do |query, text|
            { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "komsiluk" } } if own_state_category(query) == "komsiluk"
          end

          register("mz_contact") do |query, text|
            match = MZ_CONTACT.match(query)
            if match && !match[:area]&.match?(/\b(?:i|ali|pa|onda|prijavi|objavi|posalji|ne|nije|nemoj)\b/)
              entities = { "query" => text }
              entities["area_query"] = match[:area] if match[:area]
              { action: "choose_area", topic: "neighborhood", entities: }
            end
          end

          # THE FOUR QUESTIONS THE ACCOUNT MENU USED TO SWALLOW. One route
          # each, registered AFTER every built-in so none of them loses a turn
          # it answers today — the built-in prefix above is frozen order and
          # DeterministicRoutesTest asserts it. +goodwill+ is not a CORE
          # topic, so each reaches the Responder's own read-only own-state
          # handler through the secondary read adapter, which is the same path
          # "invitation" and "komsiluk" already take.
          %w(verification referrals identity invite_link).each do |name|
            register("own_state_#{name}") do |query, text|
              { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => name } } if own_state_category(query) == name
            end
          end
        end

        # REGISTERED ROUTES FROM OTHER FILES, in evaluation order after the
        # built-ins. Each line is one route; autoloading would not run their
        # top-level +register+ calls in the host's test environment.
        # First: a citizen reading the top-level menu back is answering it, not
        # asking a new question, so no later matcher may claim the wording.
        require_relative "topic_menu_route"
        require_relative "launch_topic_route"
        require_relative "personal_read_routes"
        # "What ARE the points" only ever answers what every
        # earlier route declined, so none of them loses precedence.
        require_relative "points_explainer_route"
        require_relative "transport_question_route"
      end
    end
  end
end

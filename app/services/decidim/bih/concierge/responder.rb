# frozen_string_literal: true

require_relative "emergency_signal"
require_relative "emergency_card"
require_relative "goodwill_earning_answer"
require_relative "dialogue/civic_question"
require_relative "dialogue/text_predicates"
require_relative "dialogue/contracts"

module Decidim
  module Bih
    module Concierge
      # The channel-agnostic "AI Civic Concierge" brain for the "Mi
      # pre(d)uzimamo!" bot. Given an inbound message (anything responding to
      # #text/#image_url/#latitude/#longitude — e.g. a
      # Decidim::Bih::Viber::InboundMessage) it composes the already-built
      # content services into a single best-effort reply.
      #
      # Scope: routing is deterministic keyword/heuristic first, with optional
      # Gemini NLU promotion for read-only intents. Viber also has small
      # multi-turn flows for phone linking. Legacy report and Komšiluk-post
      # requests are guidance-only until their action boundary can provide
      # actor-bound confirmation and durable idempotency.
      #
      # Intent priority (first match wins):
      #   a. STATUS   — text contains a BR-YYYY-NNNN reference
      #   b. GAZETTE  — text mentions glasnik/odluka/skupština
      #   c. BUDGET   — text mentions budžet/izdvojeno
      #   d. WASTE    — text mentions otpad/smeće/kontejner/odvoz/đubre
      #   e. DONATION — text mentions prikup/donac/donir/prilog
      #   f. GOODWILL — personal points/rank questions
      #   g. DATA STATUS — host-wired source/freshness/integration metadata
      #   h. SETUP    — registration, verification, account and notifications
      #   i. KOMSILUK POST/READ — board write/read flows
      #   j. CITY EVENT — host-wired current service alerts/outages
      #   k. LIVE SERVICE — host-wired current source summaries
      #   l. SERVICE  — directory has a relevant civic-service answer
      #   m. REPORT GUIDANCE — photo/location or explicitly classified request
      #   n. FALLBACK — a short help menu
      class Responder
        # The single reply this brain produces. +report+ is the persisted
        # Decidim::Bih::Report when the message created one, else nil. +sticker+
        # is an optional branded-sticker id (a Decidim::Bih::Concierge::Stickers
        # symbol, e.g. :prijavljeno) the channel should send AFTER the text reply,
        # best-effort; nil means "no sticker". The brain stays pure — it only
        # NAMES the sticker, the channel (Infobip) does the actual I/O.
        #
        # +quick_replies+ is an optional list of tappable civic-shortcut chips —
        # each a { label:, url: } Hash — that a CHIP-CAPABLE channel (the web
        # chat widget) renders under the text. It is populated on help/fallback
        # replies and on targeted "next action" answers where feedback showed
        # that plain text left citizens without a clear path. Channels that can't
        # render chips (Viber) simply ignore it. The reader coalesces nil to []
        # so callers can iterate unconditionally.
        # +answer_intent+ is bounded server-derived metadata for aggregate answer
        # quality review. It is never a raw prompt, reply, or classifier query.
        #
        # +locale+ is the language THIS reply is written in, which is the
        # citizen's, not the site's. Without it the channel layer has to read
        # I18n.locale, and I18n.locale is the language of the page the widget is
        # embedded in: that is how an English answer came back with a Serbian
        # phrase-bank line in front of it and Serbian chips under it. nil means
        # "not stated" — a reader falls back to the request locale, exactly as
        # before — so every existing caller keeps its behaviour.
        Reply = Struct.new(
          :text, :report, :sticker, :quick_replies, :answer_intent,
          :tone, :phrase_id, :locale, keyword_init: true
        ) do
          # Coalesce the raw member (which defaults to nil for replies built
          # without chips) to [] so callers can iterate unconditionally. Reads the
          # member by index — super would resolve to the struct's own generated
          # accessor, which this method overrides, so it can't be used here.
          def quick_replies
            self[:quick_replies] || []
          end
        end

        # Default reply language (Serbian Latin). A predominantly-Cyrillic inbound
        # message is instead answered in sr-Cyrl — see #detect_reply_locale.
        LOCALE = "sr"
        CYRILLIC_LOCALE = "sr-Cyrl"
        # Every language Milica's reviewed copy exists in. A caller that has
        # already established the conversation's language may name it; script
        # detection alone can only ever tell Latin from Cyrillic.
        REPLY_LOCALES = Dialogue::Contracts::LOCALES
        # Set by .with_reply_locale around a delegated call — see there.
        REPLY_LOCALE_OVERRIDE_KEY = :decidim_bih_concierge_reply_locale_override
        # The chosen reply locale is held per request in a thread-local: the
        # Responder may be memoized and Puma serves requests on threads, so an
        # instance variable would leak the script between concurrent citizens.
        REPLY_LOCALE_KEY = :decidim_bih_concierge_reply_locale
        PROMOTED_INTENT_KEY = :decidim_bih_concierge_promoted_intent
        PROMOTED_QUERY_KEY = :decidim_bih_concierge_promoted_query

        class << self
          # Runs +block+ with the reply language already decided, instead of
          # letting #respond re-derive it from the message's script.
          #
          # Script detection can only ever say Latin or Cyrillic. The dialogue
          # knows more than that — the turn's understanding carries the actual
          # language, including English — and when it delegates a read to this
          # brain (Coordinator::LegacyReadAdapter) that decision has to travel
          # with the call. Without it an English conversation got its budget,
          # gazette, Goodwill or launch card back in Serbian, in the middle of
          # an otherwise English answer.
          #
          # It is a scoped thread-local rather than an argument to #respond
          # because #respond is a channel-facing entry point with several test
          # doubles; widening its arity would break collaborators that have
          # nothing to do with language. The previous value is restored on the
          # way out, so nesting and an exception both leave the thread clean.
          # An unknown locale is ignored, never partially applied.
          def with_reply_locale(locale)
            previous = Thread.current[REPLY_LOCALE_OVERRIDE_KEY]
            Thread.current[REPLY_LOCALE_OVERRIDE_KEY] = locale.to_s if REPLY_LOCALES.include?(locale.to_s)
            yield
          ensure
            Thread.current[REPLY_LOCALE_OVERRIDE_KEY] = previous
          end

          # The language a caller established for this turn, or nil.
          def established_reply_locale
            value = Thread.current[REPLY_LOCALE_OVERRIDE_KEY]
            value if REPLY_LOCALES.include?(value.to_s)
          end
        end

        # A "BR-2026-0001"-style report reference anywhere in the text.
        STATUS_REFERENCE = /\bBR-\d{4}-\d+\b/i

        # Diacritic-folded trigger words for the waste-schedule intent.
        WASTE_KEYWORDS = %w(otpad smece kontejner odvoz djubre kanta).freeze

        # Diacritic-folded trigger words for the city-budget intent.
        BUDGET_KEYWORDS = %w(budzet izdvojeno).freeze

        # Filler tokens stripped (alongside the budget keywords) when extracting
        # the budget category from a question, so "koliko je izdvojeno za
        # socijalni rad" -> "socijalni rad".
        BUDGET_FILLER = %w(koliko za novca para km je u na ima).freeze

        # Diacritic-folded trigger words for the official-gazette intent.
        GAZETTE_KEYWORDS = %w(glasnik sluzbeni odluka odluku odluke skupstina skupstine).freeze

        # Diacritic-folded trigger STEMS for the donation-totals intent. Matched
        # as substrings so declensions are covered: "prikup" -> prikupljeno,
        # "donac" -> donacija/donacije, "donir" -> donirajte/donirati,
        # "prilog" -> prilog/priloga.
        DONATION_KEYWORDS = %w(prikup donac donir prilog).freeze

        # Diacritic-folded trigger STEMS for the personal-goodwill ("moji bodovi")
        # intent — how many points / what level / what rank the citizen has.
        # Matched as substrings so declensions are covered: "bodov" -> bodova/
        # bodove, "poen" -> poena, "rang" -> rang/rangu, "nivo" -> nivo/nivou,
        # "doprinos" -> doprinos/doprinosa.
        GOODWILL_KEYWORDS = %w(bodov poen rang nivo doprinos).freeze

        # Matching a reward the citizen NAMED, across Serbian cases. The host
        # catalogue reader matches whole folded words, which is why "za
        # majicu" never found "MI! majica": the accusative is not the
        # nominative. Responder#same_stem? compares stems instead, and only
        # tokens within MAX_REWARD_STEM_DRIFT characters of each other, so
        # "majicu"/"majica" is a match and "kupovinu"/"kupon" is not.
        MIN_REWARD_STEM = 4
        MAX_REWARD_STEM_DRIFT = 2

        # The neighbourhood race's two leagues, mirroring
        # Decidim::Bih::LocalArea::ZONES (the model is the owner; this brain
        # also has to load without ActiveRecord in its own unit tests).
        RACE_ZONES = %w(grad selo).freeze

        # Data/source/freshness questions are read-only. They make the host's
        # source catalog and freshness contract discoverable to citizens without
        # exposing raw prompts, secrets or operational credentials.
        DATA_STATUS_KEYWORDS = %w(
          podac izvor integracij integracije integracijama azur azurno azurni svjez svjezi
          svez svezi source sources data integration integrations
        ).freeze
        DATA_STATUS_PHRASES = [
          "koje podatke", "kakve podatke", "sta imas od podataka", "sta sve imas od podataka",
          "izvori podataka", "odakle su podaci", "jesu li podaci", "da li su podaci",
          "koliko su svjezi", "koliko su svezi", "koje integracije", "sta je povezano",
          "what data", "what sources", "data sources"
        ].freeze

        # Diacritic-folded phrases that open the phone-verification (account
        # linking) flow. "poveži" folds to "povezi"; "prijava naloga" is a phrase.
        LINK_KEYWORDS = ["povezi", "verifikuj", "registruj", "prijava naloga"].freeze

        # Account/setup questions that should never fall through to the report
        # catch-all: registration, profile/account, verification, postal letter
        # and notification setup. Komšiluk is phrase-gated below so board-read
        # questions like "šta ima u komšiluku?" keep their own intent.
        SETUP_KEYWORDS = %w(
          registr nalog profil verifik pismo postal snailmail account profile verify verification
          notifications obavjestenj obavestenj
        ).freeze
        SETUP_PHRASES = [
          "moj nalog", "my account", "javni profil", "public profile",
          "izaberi komsiluk", "odaberi komsiluk", "podesi komsiluk",
          "choose neighbourhood", "choose neighborhood", "snail mail"
        ].freeze

        # Diacritic-folded STEM that opens the komšiluk-board handoff ("objavi"/
        # "objava"/"objaviti"). It is matched by keyword only and never promoted
        # by the LLM classifier.
        POST_KEYWORDS = %w(objav).freeze

        # READING the board needs BOTH a neighbourhood word AND a "what's new"
        # query cue, so a problem report that merely mentions the neighbourhood
        # ("komšije bučno renoviraju…") is NOT hijacked into the read intent. The
        # board word "tabla" alone is unambiguous enough to trigger on its own.
        KOMSILUK_AREA_WORDS = %w(komsiluk kvart susjedstv).freeze
        KOMSILUK_READ_CUES = [
          "sta ima", "ima li", "ima sta", "ima nesto", "sta se desava",
          "sta se dogadja", "novost", "objave", "dogadjanja"
        ].freeze

        # Split for the same reason the courtesy matchers are (see
        # Dialogue::Courtesy): a bare "help", "menu" or "commands" is written
        # in English, and the reply to it must be too. The union is the list
        # this constant always held.
        LOCAL_HELP_KEYWORDS = %w(pomoc meni komande upute).freeze
        ENGLISH_HELP_KEYWORDS = %w(help menu commands).freeze
        HELP_KEYWORDS = (LOCAL_HELP_KEYWORDS + ENGLISH_HELP_KEYWORDS).freeze
        HELP_PHRASES = [
          "sta sve mozes", "sta mozes", "sta znas", "kako radis",
          "pomozi mi", "treba mi pomoc", "sta umijes", "sta umes",
          "what can you do", "what do you do"
        ].freeze

        # A cancellation is handled before every pending flow. The standalone
        # commands cover the common short replies, while the negative-action
        # pattern catches explicit "do not submit/publish/continue/link" text.
        # It deliberately does not match difficulty statements such as "ne mogu
        # da se registrujem", which still need setup guidance.
        CANCEL_COMMANDS = %w(odustani odustajem otkazi prekini cancel).freeze
        CANCEL_ACTION_PATTERN = /\b(?:ne|nemoj|necu)\s+(?:zelim\s+)?(?:da\s+)?(?:objav\w*|prijav\w*|nastav\w*|povez\w*|registr\w*)\b/

        # Fixed high-risk flows. These checks deliberately run before every
        # civic intent and before the broad report catch-all. Milica must never
        # decorate an immediate-danger, sensitive-data or legal-allegation
        # answer with humour, nor turn one into an ordinary municipal report.
        IMMEDIATE_DANGER_PHRASES = [
          "neko mi prijeti", "neko mi preti", "prijeti mi", "prete mi", "prijete mi",
          "dobijam prijetnje", "dobijam pretnje", "hoce da me ubije", "hoće da me ubije",
          "neposredna opasnost", "u opasnosti sam", "napadnut sam", "napadnuta sam",
          "porodicno nasilje", "porodično nasilje", "nasilje u porodici", "hitna pomoc",
          "hitna pomoć", "zovi policiju", "call the police", "someone is threatening me",
          "immediate danger", "domestic violence"
        ].freeze

        def self.immediate_danger?(text)
          folded = Decidim::Bih::Text.fold(text)
          IMMEDIATE_DANGER_PHRASES.any? { |phrase| folded.include?(Decidim::Bih::Text.fold(phrase)) } || EmergencySignal.call(text)
        end

        SENSITIVE_DATA_PHRASES = [
          "jmbg", "broj licne karte", "broj lične karte", "lozinka", "password",
          "broj kartice", "card number", "sigurnosni kod", "security code", "pin kartice",
          "zdravstvena dokumentacija", "medical record"
        ].freeze
        LEGAL_ALLEGATION_KEYWORDS = %w(
          korupc kriminal mito zloupotreb pronevjer pronever fraud bribery corruption
        ).freeze

        FEEDBACK_HELP_PHRASES = [
          "nije korisno", "korisno", "oznacim kao nije korisno", "označim kao nije korisno",
          "kliknem nije korisno", "sta znaci ako odgovor", "šta znači ako odgovor",
          "feedback", "not helpful", "helpful"
        ].freeze

        REPORT_GUIDANCE_PHRASES = [
          "kako da prijavim", "gdje da prijavim", "gde da prijavim",
          "hocu da prijavim", "hoću da prijavim", "zelim da prijavim", "želim da prijavim",
          "prijavim problem", "prijaviti problem",
          "kako se prijavljuje", "sta treba za prijavu", "sta da posaljem",
          "imam problem sta da radim", "imam problem sta sad",
          "how do i report", "where do i report"
        ].freeze

        PARTICIPATION_GUIDANCE_PHRASES = [
          "predlozi ideju", "predlozim ideju", "imam ideju", "podrzi prijedlog",
          "podrzim prijedlog", "podrzati prijedlog", "kako da glasam",
          "kako glasati", "budzetsko glasanje", "participativni budzet",
          "kako da ucestvujem", "how do i vote", "how to propose"
        ].freeze

        VOLUNTEER_GUIDANCE_KEYWORDS = %w(volont volonter volontir).freeze
        VOLUNTEER_GUIDANCE_PHRASES = [
          "upisem sate", "upisati sate", "evidentiram sate", "volonterske akcije",
          "gdje su akcije", "gde su akcije", "kako da pomognem", "kako volontirati",
          "how do i volunteer"
        ].freeze

        # Diacritic-folded trigger STEMS + phrases for the 17. septembar launch
        # event intent — "kako do pozivnice", "kada i gdje je lansiranje".
        # Stems cover declensions: "pozivnic" -> pozivnica/pozivnicu/pozivnice,
        # "lansiranj" -> lansiranje/lansiranja/lansiranju.
        LAUNCH_KEYWORDS = %w(pozivnic lansiranj).freeze
        # Deliberately NOT included here: bare date/venue literals like
        # "17 septembra" or "centar za kulturu". Those are a date and a place
        # name, not launch-specific intent stems — they appear naturally in
        # messages about something else entirely (e.g. an accessibility
        # complaint about the venue), and launch_reply runs BEFORE report_reply
        # in DEFAULT_HANDLERS, so matching on them would swallow a genuine
        # report. Every phrase below is itself an explicit question about the
        # event ("gdje/kada je..."), which a bare venue/date mention is not.
        LAUNCH_PHRASES = [
          "gdje je dogadjaj", "gde je dogadjaj", "kada je dogadjaj", "kad je dogadjaj",
          "how do i get an invitation", "when is the launch"
        ].freeze

        LOCAL_AREA_GUIDANCE_SCOPE_WORDS = %w(mz mjesn mesn zajednic).freeze
        LOCAL_AREA_GUIDANCE_CONTACT_WORDS = %w(predsjednik predsednik telefon kontakt).freeze
        LOCAL_AREA_GUIDANCE_PHRASES = [
          "mjesna zajednica", "mjesne zajednice", "mesna zajednica", "mesne zajednice",
          "telefon mz", "kontakt mz", "local community"
        ].freeze
        LOCATION_CONTEXT_CUES = %w(
          odavde ovdje ovde tu lokacij lokacija lokaciji lokaciju trenutn ovoj ovu ovog moj moja moje
        ).freeze
        CONTEXT_FOLLOW_UP_CUES = [
          "a ", "a do", "a koliko", "koliko", "kada", "kad", "gdje", "gde", "sta", "šta",
          "jos", "još", "do ", "za ", "ovdje", "ovde", "odavde", "tu",
          "to ", "prethodno", "prethodni", "prethodna"
        ].freeze

        # How many recent posts the read digest returns.
        KOMSILUK_DIGEST_LIMIT = 5

        # Conversation states for the linking flow (stored in the session store).
        STATE_AWAITING_PHONE = "awaiting_phone"
        STATE_AWAITING_CODE = "awaiting_code"
        # Komšiluk-post category picker: after the citizen sends the post text we
        # stash it on this state ("awaiting_komsiluk_category:<text>") and ask for
        # a category. New code no longer creates this state; it is retained only
        # to consume pre-existing sessions safely without publishing.
        STATE_AWAITING_KOMSILUK_CATEGORY = "awaiting_komsiluk_category"

        # Numbered category menu shown in the picker, in display order.
        KOMSILUK_CATEGORY_CHOICES = { "1" => "lost_pet", "2" => "safety", "3" => "activity", "4" => "general" }.freeze

        # Diacritic-folded keyword fallbacks so a citizen can also type the category.
        KOMSILUK_CATEGORY_KEYWORDS = {
          "lost_pet" => %w(izgubljen ljubimac nestao macka mace),
          "safety" => %w(bezbjednost bezbednost opasnost upozorenje sigurnost),
          "activity" => %w(aktivnost druzenje akcija dogadjaj radionica),
          "general" => %w(opste opsta ostalo)
        }.freeze

        # Filler tokens stripped when extracting the street/area from a waste
        # question, so "kada se odvozi smeće u ulici Dvorovi" -> "Dvorovi".
        WASTE_FILLER = %w(
          kada kad se odvozi odvoze odvoz vozi u na za moj moja moje mojoj mom
          iz sa s ulica ulici ulicu ulice naselje naselju kod do se li me kada da
        ).freeze

        # Ordered keyword-routing chain (first non-nil reply wins). This is the
        # exact MVP priority and the always-available fallback path.
        DEFAULT_HANDLERS = [
          :safety_reply, :status_reply, :own_state_reply, :gazette_reply, :budget_reply, :waste_reply, :donation_reply, :goodwill_reply,
          :race_standings_reply, :launch_reply,
          :data_status_reply, :setup_reply, :help_reply, :feedback_help_reply,
          :report_guidance_reply, :participation_guidance_reply,
          :volunteer_guidance_reply, :local_area_guidance_reply, :komsiluk_post_reply, :komsiluk_board_reply,
          :city_event_reply, :live_service_reply, :service_reply, :report_reply
        ].freeze

        HANDLER_ANSWER_INTENTS = {
          safety_reply: "safety",
          status_reply: "status",
          own_state_reply: "goodwill",
          gazette_reply: "gazette",
          budget_reply: "budget",
          waste_reply: "waste",
          donation_reply: "donation",
          goodwill_reply: "goodwill",
          race_standings_reply: "launch",
          launch_reply: "launch",
          data_status_reply: "data_status",
          setup_reply: "setup",
          report_guidance_reply: "report_guidance",
          feedback_help_reply: "help",
          participation_guidance_reply: "participation_guidance",
          volunteer_guidance_reply: "volunteer_guidance",
          local_area_guidance_reply: "local_area_guidance",
          komsiluk_post_reply: "komsiluk_post",
          komsiluk_board_reply: "komsiluk_read",
          city_event_reply: "city_event",
          live_service_reply: "service",
          service_reply: "service",
          report_reply: "report",
          help_reply: "help"
        }.freeze

        # Maps a classifier intent symbol onto the handler that serves it. Only
        # these intents reorder the chain. :help / :unknown — and deliberately
        # :report — are absent, so they leave the default keyword order intact.
        #
        # :report is NOT normally promotable. The host may opt into classifier-
        # driven report FORM guidance, but a label never invokes intake. Bare
        # photo/location evidence bypasses the classifier and reaches the same
        # guidance path; unknown substantive text falls back to clarification.
        INTENT_HANDLERS = {
          status: :status_reply,
          gazette: :gazette_reply,
          budget: :budget_reply,
          waste: :waste_reply,
          donation: :donation_reply,
          goodwill: :goodwill_reply,
          launch: :launch_reply,
          data_status: :data_status_reply,
          setup: :setup_reply,
          participation_guidance: :participation_guidance_reply,
          volunteer_guidance: :volunteer_guidance_reply,
          local_area_guidance: :local_area_guidance_reply,
          komsiluk_read: :komsiluk_board_reply,
          city_event: :city_event_reply,
          service: :live_service_reply,
          help: :help_reply
        }.freeze

        def initialize(organization:, directory:, waste_schedule:, # rubocop:disable Metrics/ParameterLists
                       report_intake: Decidim::Bih::ReportIntake.new,
                       budget: nil, gazette: nil, donations: nil, city_events: nil, live_service_answers: nil,
                       data_status: nil,
                       classifier: nil, image_fetcher: nil,
                       account_linking: nil, session_store: nil, goodwill_user_resolver: nil,
                       race_standings: nil, goodwill_rules: nil,
                       allow_classifier_text_report: false)
          @organization = organization
          @directory = directory
          @waste_schedule = waste_schedule
          @report_intake = report_intake
          @budget = budget
          @gazette = gazette
          @donations = donations
          @city_events = city_events
          @live_service_answers = live_service_answers
          @data_status = data_status
          @classifier = classifier
          @image_fetcher = image_fetcher
          # Channel-agnostic bridge from an inbound message to the Decidim::User
          # whose goodwill points to report. A callable (message -> Decidim::User|
          # nil); nil means "no identity available" (anonymous web v1), in which
          # case the goodwill intent answers a graceful "verify to see your
          # points" fallback. The engine stays channel-neutral; the HOST wires
          # Viber-linkage vs web-current_user resolution.
          @goodwill_user_resolver = goodwill_user_resolver
          # Optional account-linking (phone verification) deps. Both must be
          # present to enable the multi-turn linking flow; when either is nil the
          # responder behaves exactly as the single-turn MVP (no session state).
          @account_linking = account_linking
          @session_store = session_store
          # The CACHED race standings projection (Decidim::Bih::Race::Standings
          # or anything answering #leader/#computed_at/#final?). Never the
          # Scorer, and never an HTTP call to this server's own /ekran.json —
          # the projector screen and the chat read the same one table. Left nil
          # by a caller that has no organization-bound projection; the handler
          # then builds the engine's own, and says so honestly if it cannot.
          @race_standings = race_standings
          # The EFFECTIVE earning schedule (defaults -> host initializer ->
          # per-organization Setting). Nil means "resolve it from the
          # organization", which is what every channel does; a caller supplies
          # one only to pin the numbers in a test.
          @goodwill_rules = goodwill_rules
          @allow_classifier_text_report = allow_classifier_text_report
        end

        # Best-effort single reply for one inbound message. Always returns a
        # Reply (falls back to the help menu).
        #
        # Routing runs an ORDERED handler chain (first non-nil reply wins). With
        # no LLM classifier the order is the keyword-priority DEFAULT_HANDLERS
        # (GAZETTE before BUDGET: a decision question mentions "budžet" too, so
        # running gazette first stops budget from capturing it). With a
        # configured classifier the predicted intent's handler is moved to the
        # FRONT; every handler still self-gates, so a misclassification simply
        # falls through to the normal keyword chain.
        def respond(message, civic_turn: nil)
          # Reply in the language the caller established for this turn, else in
          # the script the citizen wrote in (Latin or Cyrillic).
          Thread.current[REPLY_LOCALE_KEY] = self.class.established_reply_locale || detect_reply_locale(message)

          # Red-zone safety and explicit cancellation always win over pending
          # phone/code/category state. A threat containing six digits must never
          # be coerced into an OTP, and a negated action must never continue it.
          safety = safety_reply(message)
          return safety if safety

          cancellation = cancellation_reply(message)
          return with_answer_intent(cancellation, "help") if cancellation

          # The account-linking conversation runs before the keyword/intent chain
          # so a mid-flow code or phone is interpreted as such rather than being
          # swallowed by (e.g.) the report catch-all. It self-gates and returns
          # nil whenever linking is disabled or the message isn't part of a flow.
          link_reply = link_flow_reply(message)
          return with_answer_intent(link_reply, "account_linking") if link_reply

          # Continue a pending komšiluk post awaiting its category (multi-turn
          # picker). Runs before the keyword chain so a "1"–"4" reply is read as
          # the category, not a new intent.
          category_reply = komsiluk_category_flow_reply(message)
          return with_answer_intent(category_reply, "komsiluk_post") if category_reply

          if civic_turn
            civic_turn.call { civic_reply(message) }
          else
            civic_reply(message)
          end
        ensure
          Thread.current[REPLY_LOCALE_KEY] = nil
          Thread.current[PROMOTED_INTENT_KEY] = nil
          Thread.current[PROMOTED_QUERY_KEY] = nil
        end

        private

        # The host may wrap only the civic answer portion with a server-owned
        # adapter. The safety, cancellation, account-linking and obsolete
        # category preludes in +#respond+ are deliberately outside this seam.
        def civic_reply(message)
          handler_order(message).each do |handler|
            reply = send(handler, message)
            return with_answer_intent(reply, HANDLER_ANSWER_INTENTS.fetch(handler)) if reply
          end
          with_answer_intent(fallback_reply, "help")
        end

        attr_reader :organization, :directory, :waste_schedule, :report_intake, :budget, :gazette, :donations,
                    :city_events, :live_service_answers, :data_status,
                    :classifier, :image_fetcher, :account_linking, :session_store, :goodwill_user_resolver,
                    :goodwill_rules, :allow_classifier_text_report

        def with_answer_intent(reply, answer_intent)
          return reply if reply.nil? || reply.answer_intent.present?

          reply.answer_intent = answer_intent
          reply
        end

        # --- account linking (phone verification) state machine -------------
        #
        # Drives the multi-turn flow that proves a Viber sender controls a phone:
        #   (idle) --link keyword--> awaiting_phone --phone--> awaiting_code
        #          --6-digit code--> verified (state cleared)
        # Returns a Reply when this turn belongs to the linking flow, else nil
        # (so the normal intent chain runs).
        #
        # PRECEDENCE: explicit safety/cancellation has already been handled by
        # #respond. A bare photo/location yields report-form guidance instead of
        # being coerced into a phone. A standalone 6-digit code remains an
        # unambiguous credential while the sender is awaiting one.
        def link_flow_reply(message)
          return nil unless linking_enabled?

          sender = message_sender(message)
          return nil if sender.blank?

          state = session_store.get(sender: sender)

          # (b) mid-code-entry: accept a standalone code even if an unrelated
          # attachment is present. Prose merely containing six digits is not a
          # credential and falls through safely.
          return verify_code(sender, message.text) if state == STATE_AWAITING_CODE && code_like?(message.text)

          # A genuine report (photo/location) takes precedence over the rest.
          return nil if report_signal?(message)

          # (a) awaiting a phone number and the text looks like one.
          return submit_phone(sender, message.text) if state == STATE_AWAITING_PHONE && phone_like?(message.text)

          # (c) a link keyword opens the flow.
          return open_link_flow(sender) if link_intent?(message.text)

          nil
        end

        # Both deps required; either missing falls back to single-turn behavior.
        def linking_enabled?
          !account_linking.nil? && !session_store.nil?
        end

        # The Viber sender id, or nil. Unit-test messages may not implement
        # #sender, so guard with respond_to? (per the responder contract).
        def message_sender(message)
          message.respond_to?(:sender) ? message.sender : nil
        end

        # (c) Begin the flow: remember we're awaiting a phone, ask for it.
        def open_link_flow(sender)
          session_store.set(sender: sender, state: STATE_AWAITING_PHONE)
          Reply.new(text: t("link.ask_phone"), report: nil)
        end

        # (a) Got a phone: trigger OTP send, advance to awaiting_code on success.
        def submit_phone(sender, text)
          case account_linking.start(sender: sender, phone: text)
          when :otp_sent
            session_store.set(sender: sender, state: STATE_AWAITING_CODE)
            Reply.new(text: t("link.code_sent"), report: nil)
          when :unconfigured
            # Offline development keeps the historical inspectable-code flow.
            # Production must never claim a code was sent or advance state when
            # the mandatory final phone-delivery channel is unavailable.
            if production_environment?
              Reply.new(text: t("link.send_failed"), report: nil)
            else
              session_store.set(sender: sender, state: STATE_AWAITING_CODE)
              Reply.new(text: t("link.code_sent"), report: nil)
            end
          when :rate_limited
            Reply.new(text: t("link.rate_limited"), report: nil)
          when :send_failed
            # The code was NOT delivered — stay on the phone step (do not advance
            # to awaiting_code) so the citizen can retry.
            Reply.new(text: t("link.send_failed"), report: nil)
          else # :invalid_phone
            Reply.new(text: t("link.invalid_phone"), report: nil)
          end
        end

        def production_environment?
          Rails.respond_to?(:env) && Rails.env.production?
        end

        # (b) Got a code: verify it and report the outcome, clearing state when the
        # flow is over (success or a dead/expired OTP).
        def verify_code(sender, text)
          code = text.to_s.gsub(/\D/, "")
          case account_linking.verify(sender: sender, code: code)
          when :verified
            session_store.clear(sender: sender)
            Reply.new(text: t("link.verified"), report: nil)
          when :invalid
            Reply.new(text: t("link.invalid_code"), report: nil)
          else # :expired / :no_pending
            session_store.clear(sender: sender)
            Reply.new(text: t("link.expired"), report: nil)
          end
        end

        # A link-flow opener keyword anywhere in the (diacritic-folded) text.
        def link_intent?(text)
          folded = fold(text)
          return false if folded.empty?

          LINK_KEYWORDS.any? { |keyword| folded.include?(keyword) }
        end

        # Looks like a phone number: 8–15 digits once non-digits are stripped.
        # A 6-digit OTP is deliberately below this band, so the two never collide.
        def phone_like?(text)
          value = text.to_s.strip
          return false unless value.match?(%r{\A\+?[\d\s()./-]+\z})

          digits = value.gsub(/\D/, "")
          digits.length.between?(8, 15)
        end

        # Looks like an OTP: exactly six standalone digits. Do not strip digits
        # out of arbitrary prose, since that can turn a threat, cancellation or
        # mistyped registration question into an identity operation.
        def code_like?(text)
          text.to_s.strip.match?(/\A\d{6}\z/)
        end

        # The handler chain to try, in order. A photo/location guidance signal and
        # an unconfigured/erroring classifier both keep the deterministic default
        # order; otherwise the classified intent's handler is promoted to front.
        def handler_order(message)
          # Red-zone language is deterministic and must never be displaced by
          # an optional classifier or a broad live-service match.
          return DEFAULT_HANDLERS if safety_signal?(message)

          # A report-guidance SIGNAL (photo/location) wins first: the non-report
          # handlers all bail on report_signal?, so the default order lands on
          # report_reply. Never let the LLM reinterpret bare evidence.
          return DEFAULT_HANDLERS if report_signal?(message)
          # "Imam li pozivnicu?" / "Koji je moj komšiluk?" are closed
          # own-state reads answered from the citizen's own rows; a classifier
          # label (launch, setup, goodwill) must never displace them, and there
          # is nothing for a model to add, so the classifier is not even asked.
          return DEFAULT_HANDLERS if own_state_question?(message)
          return [:live_service_reply, *(DEFAULT_HANDLERS - [:live_service_reply])] if live_service_answer_signal?(message)

          return DEFAULT_HANDLERS unless classifier&.configured?

          classified_handler_order(message)
        rescue StandardError => e
          log_failure("intent_classifier_failed", e)
          DEFAULT_HANDLERS
        end

        def classified_handler_order(message)
          result = classifier.classify(message.text)
          return DEFAULT_HANDLERS if result.nil?

          Thread.current[PROMOTED_INTENT_KEY] = result.intent
          Thread.current[PROMOTED_QUERY_KEY] = result.query
          handler = INTENT_HANDLERS[result.intent]
          handler = :report_reply if classifier_text_report_handler?(result.intent, message)
          return DEFAULT_HANDLERS if handler.nil? # :help / :unknown -> keyword order

          [handler, *(DEFAULT_HANDLERS - [handler])]
        end

        def classifier_text_report_handler?(intent, message)
          intent == :report &&
            allow_classifier_text_report &&
            !deterministic_answer_signal?(message)
        end

        # Fixed red-zone routing. The returned intent is refined in
        # +with_answer_intent+ so analytics can distinguish safety, privacy and
        # moderation without retaining the citizen's text.
        def safety_reply(message)
          folded = fold(message.text)
          return nil if folded.empty?

          return Reply.new(text: immediate_danger_text(message.text), report: nil, answer_intent: "safety", tone: "core") if
            self.class.immediate_danger?(message.text)
          return Reply.new(text: t("safety.sensitive_data"), report: nil, answer_intent: "privacy", tone: "core") if
            phrase_match?(message.text, SENSITIVE_DATA_PHRASES)
          return nil unless LEGAL_ALLEGATION_KEYWORDS.any? { |keyword| folded.include?(fold(keyword)) }

          Reply.new(text: t("safety.allegation"), report: nil, answer_intent: "moderation", tone: "core")
        end

        def safety_signal?(message)
          text = message.respond_to?(:text) ? message.text.to_s : ""
          folded = fold(text)
          self.class.immediate_danger?(text) ||
            phrase_match?(text, SENSITIVE_DATA_PHRASES) ||
            LEGAL_ALLEGATION_KEYWORDS.any? { |keyword| folded.include?(fold(keyword)) }
        end

        # The answer to immediate danger on a channel that runs THIS brain and
        # not the dialogue coordinator — the dormant Viber Bot, and the web
        # whenever v1 is off. EmergencySignal recognises fire, gas, flood,
        # trapped and medical danger since Task 2, so those citizens were being
        # handed the police-first line instead of the service that actually
        # comes out to them. A danger this module cannot type (a threat, an
        # assault) keeps the reviewed red-zone copy, which names the police and
        # also tells the citizen not to post personal data here.
        def immediate_danger_text(text)
          EmergencyCard.typed(text, fallback_locale: reply_locale) || t("safety.immediate_danger")
        end

        # Stop a pending or newly negated action without invoking any effect.
        # The existing help menu is used because shared locale files are owned by
        # the integrator in this wave; it keeps a useful, localized next step.
        def cancellation_reply(message)
          return nil unless cancellation_signal?(message.text)

          clear_pending_flow(message)
          fallback_reply
        end

        # The negated-action half only counts in the FIRST clause, which is the
        # one place an actual cancellation lives. Unanchored, this pattern read
        # "treba mi službena stranica toplane, ne prijava problema" as a
        # cancellation and threw away the positive request the citizen made.
        # Dialogue::TextPredicates.cancel_action? is the same rule the dialogue
        # path uses (ProcedureRunner.cancellation_wording?), so the two brains
        # can no longer disagree about what "cancel" means.
        def cancellation_signal?(text)
          # Normalised exactly as ProcedureRunner.cancellation_wording? does it,
          # so the two brains cannot disagree on the input either.
          folded = fold(text).gsub(/[^a-z0-9\s]/, " ").split.join(" ")
          return false if folded.empty?
          return true if CANCEL_COMMANDS.include?(folded.split.first)
          return true if folded.match?(/\Astop(?:\s+molim)?\z/)

          Dialogue::TextPredicates.cancel_action?(folded, CANCEL_ACTION_PATTERN)
        end

        def clear_pending_flow(message)
          return unless session_store && message_sender(message).present?

          state = session_store.get(sender: message_sender(message))
          return unless pending_flow_state?(state)

          session_store.clear(sender: message_sender(message))
        end

        def pending_flow_state?(state)
          state == STATE_AWAITING_PHONE ||
            state == STATE_AWAITING_CODE ||
            state.to_s.start_with?("#{STATE_AWAITING_KOMSILUK_CATEGORY}:")
        end

        def phrase_match?(text, phrases)
          normalized = fold(text)
          phrases.any? { |phrase| normalized.include?(fold(phrase)) }
        end

        # a. STATUS
        def status_reply(message)
          match = message.text.to_s.match(STATUS_REFERENCE)
          return nil unless match

          reference = match[0].upcase
          report = Decidim::Bih::Report.find_by(organization: organization, reference: reference)
          return Reply.new(text: status_not_found_text(reference), report: nil) unless report

          Reply.new(text: status_found_text(report), report: report)
        end

        # b. BUDGET — how much the city allocated for a category. Skipped when
        # the dependency is absent or the message is clearly a report.
        def budget_reply(message)
          return nil if budget.nil? || report_signal?(message)

          folded = fold(message.text)
          return nil unless promoted_query_for(:budget) || BUDGET_KEYWORDS.any? { |keyword| folded.include?(keyword) }

          category = promoted_query_for(:budget) || budget_category(message.text)
          return Reply.new(text: t("budget.ask"), report: nil) if category.blank?

          amount = budget.amount_for(category)
          text =
            if amount
              t("budget.found", category: category,
                                amount: ActiveSupport::NumberHelper.number_to_delimited(amount, delimiter: "."),
                                year: budget.year)
            else
              t("budget.not_found", category: category)
            end
          Reply.new(text: text, report: nil)
        end

        # c. GAZETTE — official-gazette decisions. Skipped when the dependency is
        # absent, the message is clearly a report, or there is no text.
        def gazette_reply(message)
          return nil if gazette.nil? || report_signal?(message)

          folded = fold(message.text)
          return nil if folded.empty?
          return nil unless promoted_query_for(:gazette) || GAZETTE_KEYWORDS.any? { |keyword| folded.include?(keyword) }

          # Once a gazette keyword is present this intent OWNS the message (it
          # never falls through to budget), so a miss answers not_found.
          top = gazette.search(promoted_query_for(:gazette) || message.text, limit: 1).first
          text =
            if top
              t("gazette.found", number: top[:number], date: top[:date],
                                 url: top[:url], detail: top[:summary].to_s).strip
            else
              t("gazette.not_found")
            end
          Reply.new(text: text, report: nil)
        end

        # d. WASTE — but a photo/location always gets report guidance, even if the
        # caption mentions waste, so yield those to the report intent.
        def waste_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil if folded.empty?
          return nil unless promoted_query_for(:waste) || WASTE_KEYWORDS.any? { |keyword| folded.include?(keyword) }

          query = waste_query(promoted_query_for(:waste) || message.text)
          Reply.new(text: waste_reply_text(query), report: nil)
        end

        # e. DONATION — how much has been raised via the Odoo webshop. A single
        # general-fund "total raised" figure (amount + donation count), not a
        # per-project bar. Skipped when the dependency is absent or the message
        # is clearly a report. Reads the host-wired cached totals, so it never
        # blocks the bot on Odoo.
        def donation_reply(message)
          return nil unless Decidim::Bih.donations_provider_available_for?(donations, organization:)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil if folded.empty?
          return nil unless promoted_intent?(:donation) || DONATION_KEYWORDS.any? { |keyword| folded.include?(keyword) }

          totals = donations.totals
          amount = ActiveSupport::NumberHelper.number_to_delimited(totals.total.to_i, delimiter: ".")
          # STICKER (documented one-liner): a donation/thanks moment maps to the
          # ":hvala" sticker in the design kit. To enable it, add
          # `sticker: :hvala` to the Reply below — the channel already sends any
          # Reply#sticker after the text, best-effort. Left off for now because
          # this handler ANSWERS a "how much was raised?" query rather than
          # confirming a fresh donation, so a sticker on every total lookup would
          # be noise. Likewise a recorded budget vote would map to `:glas`.
          Reply.new(
            text: t("donation.found", amount: amount, currency: donations.currency_label,
                                      count: totals.count, url: donations.donate_url),
            report: nil
          )
        end

        # e2. PERSONAL GOODWILL — "moji bodovi": the citizen's points balance,
        # recognition level and leaderboard rank. READ-ONLY: it only ever READS
        # the ledger cache — it NEVER awards, spends, gifts or otherwise mutates
        # points (and never touches the budget vote). Skipped when the message is
        # clearly a report or carries none of the goodwill keywords.
        #
        # Identity: resolved via the host-wired goodwill_user_resolver (Viber
        # linkage / web current_user). When no user can be resolved (anonymous or
        # unlinked chat — the common case, and the ONLY case for web v1) it
        # answers a graceful "verify/link to see your points" reply pointing at
        # /biceriseno/moj-doprinos, rather than falling through to report_reply.
        def goodwill_reply(message)
          return nil if report_signal?(message)

          text = message.text.to_s
          folded = fold(text)
          return nil if folded.empty?

          goodwill_answer(message, text, folded)
        end

        # The order the questions narrow, and nothing else.
        def goodwill_answer(message, text, folded)
          # AFFORDABILITY first, because every other branch below answers half
          # of it. The balance answers "how many do I have" and the catalogue
          # answers "what does it cost", and a citizen who asked whether the
          # first covers the second gets a complete-sounding sentence that
          # never made the comparison.
          affordability = goodwill_affordability_reply(message, text, folded)
          return affordability if affordability

          # Five different questions used to collapse into one catalogue dump.
          # The four RULE questions are answered before identity is resolved,
          # because they are the same for every citizen — including an
          # anonymous one — and because reading a ledger to answer them would
          # be a personal read the question never asked for.
          rules = goodwill_rules_reply(text, folded)
          return rules if rules
          return nil unless promoted_intent?(:goodwill) || GOODWILL_KEYWORDS.any? { |keyword| folded.include?(keyword) }

          goodwill_balance_reply(message)
        end

        # Identity is the resolved user, and only when the conversation's
        # trusted scope names that same actor and this organization: a scope
        # minted for another account, or a user from another tenant, gets the
        # sign-in hand-off and no numbers at all.
        def goodwill_balance_reply(message)
          user = own_state_user(message)
          return goodwill_sign_in_reply if user.nil?

          account = goodwill_account_for(user)
          return Reply.new(text: t("goodwill.none", url: contribution_url), report: nil) if no_points?(account)

          Reply.new(text: goodwill_found_text(account, account.level, goodwill_rank_for(account)), report: nil, sticker: :glas)
        end

        # "Da li imam dovoljno bodova za majicu?" — the comparison, in one
        # sentence, from BOTH sources of truth and neither of them typed: the
        # price is the reward's own `cost` in the admin catalogue, the balance
        # is the citizen's ledger row read through the same authorized port
        # every other own-state answer uses (resolved user, matching
        # organization, matching trusted scope, re-read on every turn and
        # never from a retained memory — AnswerContext refuses to retain it).
        #
        # It declines rather than guesses. A question that names no reward we
        # stock falls through to the catalogue, which is the honest answer to
        # "do I have enough for a thing we do not offer"; an unreadable
        # catalogue falls through too. An anonymous chat gets the sign-in
        # hand-off and no number at all.
        #
        # Nothing here redeems, reserves or holds anything: it is two reads and
        # a subtraction. Points stay recognition, never power.
        def goodwill_affordability_reply(message, text, folded)
          return nil unless Dialogue::PersonalReadRoutes.affordability?(folded, text)

          reward = affordable_reward_for(folded)
          return nil if reward.nil?

          user = own_state_user(message)
          return goodwill_sign_in_reply if user.nil?

          cost = reward.cost.to_i
          balance = goodwill_account_for(user)&.balance.to_i
          values = { reward: reward.name, cost: points(cost), balance: points(balance), url: rewards_url }
          return Reply.new(text: t("goodwill.affordability.enough", **values), report: nil) if balance >= cost

          Reply.new(text: t("goodwill.affordability.not_enough", **values, missing: points(cost - balance), rules_url: rules_url), report: nil)
        end

        # The one reward this question names, or nil. Matched against the
        # catalogue's own rows in the reply locale — never a hard-coded list
        # and never a price repeated in copy. See MIN_REWARD_STEM.
        def affordable_reward_for(folded)
          tokens = folded.split(/\s+/).select { |token| token.length >= MIN_REWARD_STEM }
          return nil if tokens.empty?

          named = redeemable_rewards.select { |reward| reward_named_by?(reward, tokens) }
          # Exactly one reward, or nothing. Two matches means the question did
          # not single one out, and comparing a balance against a price the
          # citizen did not ask for is worse than handing them the catalogue.
          named.length == 1 ? named.first : nil
        end

        # The catalogue a citizen can actually spend points on: the shared
        # reader's own list, minus the threshold rewards it already drops and
        # minus anything whose offer has run out.
        #
        # STOCK is deliberately NOT filtered. "Do I have enough points for the
        # shirt?" is a question about their balance, not about this minute's
        # inventory, and refusing the comparison because the last shirt is
        # spoken for would answer nothing at all. Stock is re-checked at
        # redemption, on the page this answer links to, which is where it
        # belongs — and checking it here would also be one COUNT per reward
        # inside a turn that is on a deadline.
        def redeemable_rewards
          I18n.with_locale(reply_locale) do
            Decidim::Bih::Goodwill::RewardsCatalog.manually_redeemable(organization)
                                                  .reject { |reward| reward.respond_to?(:expired?) && reward.expired? }
          end
        rescue StandardError => e
          log_failure("reward_catalog_unavailable", e)
          []
        end

        def reward_named_by?(reward, tokens)
          terms = fold(reward.name.to_s).split(/\s+/).select { |word| word.length >= MIN_REWARD_STEM }
          return false if terms.empty?

          terms.any? { |term| tokens.any? { |token| same_stem?(term, token) } }
        end

        # Two folded words are the same noun in different cases when they are
        # within two characters of each other in length and agree on every
        # character up to the shorter one's last two.
        def same_stem?(first, second)
          return false if (first.length - second.length).abs > MAX_REWARD_STEM_DRIFT

          shared = [first.length, second.length].min - MAX_REWARD_STEM_DRIFT
          shared = MIN_REWARD_STEM if shared < MIN_REWARD_STEM
          first[0, shared] == second[0, shared]
        end

        def rewards_url = Decidim::Bih.public_path("zajednistvo?tab=nagrade")

        # The rule half of the goodwill subject, in the order the questions
        # narrow: the daily cap, the referral, a requested earning action, then
        # the schedule as a whole. All four are read-only and identity-free.
        def goodwill_rules_reply(text, folded)
          category = Dialogue::PersonalReadRoutes
          return goodwill_daily_cap_reply if category.cap?(folded, text)
          return goodwill_referral_reply(pending: category.referral_pending?(folded, text)) if category.referral?(folded, text)
          return goodwill_earning_reply(text) if Dialogue::CivicQuestion.earning?(text)

          nil
        end

        # No identity resolved: say which numbers exist and where to sign in.
        # Never a guessed zero, and never the rewards catalogue.
        def goodwill_sign_in_reply
          Reply.new(text: [t("goodwill.not_linked", url: contribution_url),
                           dialogue_t("handoff_sign_in", url: sign_in_url)].join("\n"), report: nil)
        end

        # The earning rules from the single effective schedule (never typed
        # numbers), ending with the public rules page. Read-only.
        #
        # When the citizen NAMED an action ("koliko bodova za poziv komšiji"),
        # that action is answered directly. Ranking the top five silently
        # dropped `referral`, which is exactly the action most often asked
        # about by name.
        def goodwill_earning_reply(text = nil)
          action = text && GoodwillEarningAnswer.requested_action(text)
          Reply.new(text: GoodwillEarningAnswer.call(organization:, locale: reply_locale, action:, rules: goodwill_rules), report: nil)
        end

        # "Koliko bodova nosi poziv komšiji" is served by the schedule above;
        # this answers the parts of the referral that are NOT a number: the
        # 24-hour wait, the activity gate and the monthly limit. It never
        # inspects the invited neighbour's account — it cannot and must not.
        def goodwill_referral_reply(pending: false)
          values = GoodwillEarningAnswer.referral_values(organization:, locale: reply_locale, rules: goodwill_rules)
          lines = [dialogue_t("goodwill_referral", **values)]
          lines << dialogue_t("goodwill_referral_pending", hours: values.fetch(:hours)) if pending
          Reply.new(text: lines.join("\n"), report: nil)
        end

        # The documented product rule no answer has ever stated: an action over
        # its daily cap still executes and simply earns nothing.
        def goodwill_daily_cap_reply
          Reply.new(text: dialogue_t("goodwill_daily_cap", **GoodwillEarningAnswer.cap_values(organization:, locale: reply_locale, rules: goodwill_rules)),
                    report: nil)
        end

        # e3. RACE STANDINGS — "ko trenutno vodi?". The grad and selo leaders
        # from the CACHED standings table, with the moment they were computed.
        # READ-ONLY and aggregate: a komšiluk name and a score, never a person,
        # never a report and never a donor. Nothing here recomputes the race —
        # the Scorer is not called, and neither is this server's own
        # /ekran.json; both surfaces read the same one table.
        #
        # A frozen (final) table is labelled as final, a readable one is
        # labelled with its timestamp, and an unreadable one says so instead of
        # printing a number nobody can stand behind.
        def race_standings_reply(message)
          return nil if report_signal?(message)

          text = message.text.to_s
          return nil unless Dialogue::PersonalReadRoutes.race_standings?(fold(text), text)

          unless Decidim::Bih::Race::Visibility.visible?(organization)
            return Reply.new(text: I18n.t("decidim.bih.community_hub.race.hidden", locale: I18n.locale), report: nil)
          end
          standings = race_standings
          return Reply.new(text: dialogue_t("race_standings_unavailable", url: race_url), report: nil) if standings.nil?

          lines = [dialogue_t("race_standings_intro")]
          race_zones.each { |zone| lines << race_leader_line(standings, zone) }
          lines << race_standings_footer(standings)
          Reply.new(text: lines.join("\n"), report: nil)
        rescue StandardError => e
          log_failure("race_standings_unavailable", e)
          Reply.new(text: dialogue_t("race_standings_unavailable", url: race_url), report: nil)
        end

        # The race's two leagues. The model owns the list; the channel-agnostic
        # brain must still load without ActiveRecord, hence the literal fallback.
        def race_zones
          Decidim::Bih::LocalArea::ZONES
        rescue NameError
          RACE_ZONES
        end

        def race_leader_line(standings, zone)
          label = dialogue_t("race_standings_zone_#{zone}")
          leader = standings.leader(zone)
          return dialogue_t("race_standings_no_leader", zone: label) if leader.nil?

          dialogue_t("race_standings_leader", zone: label, name: leader.display_name, score: leader.score)
        end

        def race_standings_footer(standings)
          return dialogue_t("race_standings_final", url: race_url) if standings.final?

          computed = standings.computed_at
          return dialogue_t("race_standings_unknown_time", url: race_url) if computed.nil?

          dialogue_t("race_standings_observed", time: race_time(computed), url: race_url)
        end

        def race_time(value)
          value.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y. %H:%M")
        rescue StandardError
          value.to_s
        end

        # The engine's own cached projection when the channel wired none. A
        # missing Race namespace (an older host) is a nil, not a backtrace.
        def race_standings
          return @race_standings if defined?(@race_standings) && @race_standings

          @race_standings = Decidim::Bih::Race::Standings.new(organization)
        rescue StandardError
          nil
        end

        def race_url = Decidim::Bih.public_path("zajednistvo?tab=trka")

        # e2'. OWN STATE — "imam li pozivnicu?", "koji je moj komšiluk?": the
        # citizen's launch invitation (the auto-issued `pozivnica_lansiranje`
        # reward fulfillment, with the reservation number the door checks) and
        # the komšiluk chosen on their profile. READ-ONLY: nothing is issued,
        # confirmed, assigned or awarded by asking. Identity is the resolved
        # user, and only when the conversation's trusted scope (where the
        # channel carries one) names that same actor and this organization —
        # a scope minted for another account gets the sign-in hand-off and no
        # data at all. Deterministic (Dialogue::CivicQuestion), so it runs
        # ahead of the launch/setup/goodwill keyword handlers.
        #
        # Answer intent is "goodwill" on purpose: the reservation number and
        # the komšiluk are private facts, and the web transcript cache only
        # neutralizes goodwill answers before they become next-turn model input.
        def own_state_reply(message)
          category = Dialogue::CivicQuestion.own_state(message.text.to_s)
          return nil if category.nil? || report_signal?(message)
          # The invite page is PUBLIC: the personal link and its printable QR
          # live on a page anyone can open, so naming it needs no identity,
          # no ledger and no authorization. It is answered before the user is
          # resolved precisely so an anonymous citizen gets the answer rather
          # than a sign-in hand-off to something they can already read.
          return invite_link_reply if category == "invite_link"

          user = own_state_user(message)
          return own_state_sign_in_reply(category) if user.nil?

          own_state_answer(category, user)
        end

        # One answer per category. Each performs its own read; none of them
        # sees another's.
        def own_state_answer(category, user)
          case category
          when "invitation" then invitation_state_reply(user)
          when "komsiluk" then komsiluk_state_reply(user)
          when "verification" then verification_state_reply(user)
          when "referrals" then referral_count_reply(user)
          when "identity" then identity_state_reply(user)
          end
        end

        def own_state_question?(message)
          text = message.respond_to?(:text) ? message.text.to_s : ""
          !Dialogue::CivicQuestion.own_state(text).nil?
        end

        # The resolved user, or nil when the conversation may not read their
        # rows: no identity, a foreign organization, or a trusted scope whose
        # actor is someone else (an account switch the channel did not reset).
        def own_state_user(message)
          user = resolve_goodwill_user(message)
          return nil if user.nil?
          return nil if user.respond_to?(:decidim_organization_id) && user.decidim_organization_id != organization.id

          scope = message.respond_to?(:trusted_context) ? message.trusted_context : nil
          return user if scope.nil? || own_state_scope?(scope, user)

          log_failure("own_state_actor_scope_mismatch", nil)
          nil
        end

        def own_state_scope?(scope, user)
          actor_id = scope.respond_to?(:actor_id) ? scope.actor_id : nil
          organization_id = scope.respond_to?(:organization_id) ? scope.organization_id : organization.id
          actor_id == user.id && organization_id == organization.id &&
            (!scope.respond_to?(:allows?) || scope.allows?("own_report_reads"))
        end

        def own_state_sign_in_reply(category)
          lines = [t("account_state.#{category}.sign_in"), dialogue_t("handoff_sign_in", url: sign_in_url)]
          text = lines.join("\n")
          # The launch facts are public; an anonymous "kad je lansiranje" still
          # deserves the where and when.
          text = [text, t("launch.answer", url: community_hub_url)].join("\n\n") if category == "invitation"
          Reply.new(text:, report: nil)
        end

        def invitation_state_reply(user)
          invitation = launch_invitation_for(user)
          return issued_invitation_reply(invitation) if invitation

          reward = launch_invitation_reward
          return Reply.new(text: t("account_state.invitation.unavailable", hub_url: community_hub_url), report: nil) if reward.nil? || reward.expired?

          # The threshold is the catalogue's cost and the progress is the
          # ledger's recognition score — the same two numbers LaunchInvitation
          # compares when it issues. Never a typed literal.
          threshold = reward.cost.to_i
          score = goodwill_account_for(user)&.contribution_score.to_i
          if score >= threshold
            return Reply.new(text: t("account_state.invitation.reached", threshold: points(threshold), score: points(score), hub_url: community_hub_url),
                             report: nil)
          end

          text = t("account_state.invitation.not_yet", threshold: points(threshold), score: points(score),
                                                       missing: points(threshold - score), rules_url: rules_url)
          text = [text, dialogue_t("handoff_verify", url: verification_url)].join("\n") unless sms_authorized?(user)
          Reply.new(text:, report: nil)
        end

        def issued_invitation_reply(invitation)
          key = invitation_state_key(invitation)
          code = invitation.respond_to?(:entry_code) ? invitation.entry_code.to_s.strip : ""
          return Reply.new(text: t("account_state.invitation.#{key}", hub_url: community_hub_url), report: nil) if %w(fulfilled canceled).include?(key)
          return Reply.new(text: t("account_state.invitation.#{key}_without_code", hub_url: community_hub_url), report: nil) if code.empty?

          # The reservation number is an identifier: never transliterated.
          Reply.new(text: t("account_state.invitation.#{key}", code:, hub_url: community_hub_url), report: nil)
        end

        def invitation_state_key(invitation)
          case invitation.status.to_s
          when "fulfilled" then "fulfilled"
          when "canceled", "reversed" then "canceled"
          else
            confirmed = invitation.respond_to?(:attendance_confirmed_at) && invitation.attendance_confirmed_at.present?
            confirmed ? "confirmed" : "reserved"
          end
        end

        def komsiluk_state_reply(user)
          profile = citizen_profile_for(user)
          area = profile&.komsiluk
          area = nil unless own_area?(area, "komsiluk")
          if area.nil?
            text = [t("account_state.komsiluk.none"), dialogue_t("handoff_choose_area", url: komsiluk_url)].join("\n")
            return Reply.new(text:, report: nil)
          end

          mz = profile.mz
          mz = area.primary_mz unless own_area?(mz, "mz")
          mz = nil unless own_area?(mz, "mz")
          values = { komsiluk: area_display_name(area), board_url: komsiluk_board_url, url: komsiluk_url }
          return Reply.new(text: t("account_state.komsiluk.assigned_without_mz", **values), report: nil) if mz.nil?

          Reply.new(text: t("account_state.komsiluk.assigned", **values, mz: area_display_name(mz)), report: nil)
        end

        # "Da li sam verifikovan?" — the citizen's OWN verification state, read
        # fresh through AccountSummary, which re-reads the authorization rows
        # on every call. Three independent facts and they are not the same
        # one: the phone (the `sms` authorization, which IS the identity on
        # this host), the address letter (`postal_letter`) and the proven
        # e-mail (`mi_email_confirmed` — never Devise's `confirmed?`, which
        # `skip_confirmation!` sets at sign-up and which therefore proves
        # nothing here). An unreadable summary answers nothing rather than
        # guessing a "no": telling a verified citizen they are not verified is
        # worse than telling them to look at the page.
        def verification_state_reply(user)
          summary = account_summary_for(user)
          return nil if summary.nil?

          phone = summary.sms_verified?
          key = phone ? "verified" : "not_verified"
          lines = [t("account_state.verification.#{key}", account_url: account_url)]
          lines << t("account_state.verification.postal_#{summary.postal_verified? ? "done" : "open"}", url: verification_url)
          lines << t("account_state.verification.email_#{email_proven?(user) ? "done" : "open"}")
          lines << dialogue_t("handoff_verify", url: verification_url) unless phone
          Reply.new(text: lines.join("\n"), report: nil)
        end

        def account_summary_for(user)
          return nil unless user.respond_to?(:decidim_organization_id) && user.decidim_organization_id == organization.id

          Decidim::Bih::AccountSummary.new(organization:, user:)
        rescue StandardError => e
          log_failure("account_summary_unavailable", e)
          nil
        end

        def email_proven?(user)
          Decidim::Bih::EmailConfirmation.confirmed?(user) == true
        rescue StandardError
          false
        end

        # "Koliko sam ljudi pozvao?" — a COUNT, not the referral rules. The
        # deployed goodwill_referral route needs a points word in the sentence,
        # so this question could never reach it; it also asks something that
        # route does not answer. Scoped to this organization AND this referrer,
        # so another citizen's rows are unreachable by construction, and it
        # names nobody: how many, how many have paid, and nothing about who.
        def referral_count_reply(user)
          counts = referral_counts_for(user)
          return nil if counts.nil?

          made, rewarded = counts
          return Reply.new(text: t("account_state.referrals.none", url: invite_url), report: nil) if made.zero?

          lines = [t("account_state.referrals.count", count: made, rewarded: rewarded, url: invite_url)]
          lines << t("account_state.referrals.pending", count: made - rewarded, hours: referral_wait_hours) if made > rewarded
          Reply.new(text: lines.join("\n"), report: nil)
        end

        # [made, rewarded] or nil when the ledger cannot be read. Read-only and
        # never creates: two counts over one index.
        def referral_counts_for(user)
          scope = Decidim::Bih::Goodwill::Referral.where(decidim_organization_id: organization.id, referrer_id: user.id)
          [scope.count, scope.rewarded.count]
        rescue StandardError => e
          log_failure("referral_count_unavailable", e)
          nil
        end

        def referral_wait_hours
          delay = Decidim::Bih::Goodwill::ReferralRewardJob::REWARD_DELAY
          hours = delay.respond_to?(:in_hours) ? delay.in_hours.round : Integer(delay) / 3600
          hours.positive? ? hours : 24
        rescue StandardError
          24
        end

        # "Kako se zovem?" — the citizen's own name, to their own signed-in
        # session, after own_state_user has already proved the conversation's
        # trusted scope names this actor and this organization. The nickname is
        # included because it is also their public profile handle and the code
        # their invite link is built from; nothing else about the account is.
        def identity_state_reply(user)
          name = user.respond_to?(:name) ? user.name.to_s.strip : ""
          nickname = user.respond_to?(:nickname) ? user.nickname.to_s.strip : ""
          return Reply.new(text: t("account_state.identity.unknown", url: account_url), report: nil) if name.empty? && nickname.empty?
          return Reply.new(text: t("account_state.identity.name_only", name: name, url: account_url), report: nil) if nickname.empty?
          return Reply.new(text: t("account_state.identity.nickname_only", nickname: nickname, url: account_url), report: nil) if name.empty?

          Reply.new(text: t("account_state.identity.known", name: name, nickname: nickname, url: account_url), report: nil)
        end

        # "Gdje je moj link za pozivanje komšija?" — the page, not the link.
        # The page carries the citizen's own link and a printable QR and is
        # readable signed in or not, so this answers without a read of any
        # kind. It never prints a personal code: an anonymous session has none
        # and a signed-in one is one tap from its own.
        def invite_link_reply
          Reply.new(text: t("account_state.invite_link.answer", url: invite_url), report: nil)
        end

        def invite_url
          Decidim::Bih.invite_path
        rescue StandardError
          Decidim::Bih.public_path("zajednistvo?tab=pozovi")
        end

        def own_area?(area, kind)
          return false if area.nil?
          return false if area.respond_to?(:kind) && area.kind != kind

          !area.respond_to?(:decidim_organization_id) || area.decidim_organization_id == organization.id
        end

        # Historical launch facts. New issuance and private invitation state
        # use the live reward and expiry gates separately.
        def launch_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil unless promoted_intent?(:launch) || launch_intent?(folded)

          Reply.new(text: t("launch.answer", url: community_hub_url), report: nil)
        end

        # e2b. DATA STATUS — "koje podatke imaš / jesu li izvori ažurni".
        # Host-owned provider returns bounded metadata about available datasets,
        # freshness and integrations. This is read-only and safe to LLM-promote.
        def data_status_reply(message)
          return nil if data_status.nil? || report_signal?(message)

          folded = fold(message.text)
          return nil unless promoted_intent?(:data_status) || data_status_intent?(folded)

          Reply.new(text: data_status_answer, report: nil)
        end

        # e2c. SETUP / ONBOARDING — registration, account, verification, postal
        # letter, Komšiluk setup and notifications. Must run before the report
        # catch-all so "kako da se registrujem?" does not become report guidance.
        def setup_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil if folded.empty?
          return nil unless setup_intent?(folded) || promoted_intent?(:setup)

          Reply.new(
            text: t(
              "setup.answer",
              register_url: registration_url,
              account_url: account_url,
              verification_url: verification_url,
              komsiluk_url: komsiluk_url,
              notifications_url: notifications_url
            ),
            report: nil
          )
        end

        def report_guidance_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil unless report_guidance_intent?(folded)

          Reply.new(text: t("report_guidance.answer", url: report_form_url(message)), report: nil,
                    quick_replies: report_quick_replies(message))
        end

        def feedback_help_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil unless feedback_help_intent?(folded)

          Reply.new(text: t("feedback_help.answer"), report: nil)
        end

        def participation_guidance_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil unless promoted_intent?(:participation_guidance) || participation_guidance_intent?(folded)

          Reply.new(text: t("participation_guidance.answer", url: participation_url), report: nil)
        end

        def volunteer_guidance_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil unless promoted_intent?(:volunteer_guidance) || volunteer_guidance_intent?(folded)

          Reply.new(text: t("volunteer_guidance.answer", url: volunteer_url), report: nil)
        end

        def local_area_guidance_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return local_area_current_location_reply(message) if local_area_current_location_intent?(folded)

          area = find_mz_area(promoted_query_for(:local_area_guidance).presence || message.text)
          return nil unless local_area_guidance_requested?(folded, area)

          return Reply.new(text: t("local_area_guidance.index", url: mz_directory_url), report: nil) unless area

          Reply.new(
            text: t(
              "local_area_guidance.found",
              name: local_area_name(area),
              president: local_area_president(area),
              phone: area.telefon.presence || t("local_area_guidance.no_contact"),
              url: mz_area_url(area)
            ),
            report: nil
          )
        end

        def local_area_current_location_reply(message)
          return local_area_location_reply(message) if message_has_location?(message)

          Reply.new(text: t("local_area_guidance.ask_location", url: komsiluk_url), report: nil)
        end

        def local_area_guidance_requested?(folded, area)
          promoted_intent?(:local_area_guidance) ||
            local_area_guidance_intent?(folded) ||
            (local_area_contact_intent?(folded) && area)
        end

        # e2. KOMŠILUK POST GUIDANCE — the legacy responder has no confirmation
        # bound to actor/organization/draft revision and no durable idempotency
        # receipt. It therefore never publishes. The moderated board remains the
        # supported place to choose a category, preview and confirm the post.
        def komsiluk_post_reply(message)
          return nil if report_signal?(message)

          folded = fold(message.text)
          return nil unless POST_KEYWORDS.any? { |keyword| folded.include?(keyword) }

          Reply.new(text: t("komsiluk.post.web_guidance", url: komsiluk_board_url), report: nil)
        end

        # Old deployments may still have a pending category state in the shared
        # session store. Consume it safely: exact category input receives the
        # board handoff, but never publishes. Unknown input clears the obsolete
        # state and falls through to ordinary clarification/help.
        def komsiluk_category_flow_reply(message)
          return nil unless komsiluk_picker_available?(message)

          sender = message_sender(message)
          state = session_store.get(sender:)
          return nil unless state&.start_with?("#{STATE_AWAITING_KOMSILUK_CATEGORY}:")

          session_store.clear(sender:) # the pick ends this turn either way

          # A photo/location is evidence only and yields report-form guidance;
          # never reinterpret it as a category selection.
          return nil if report_signal?(message)

          category = parse_komsiluk_category(message.text)
          return nil if category.nil? # not a category → let normal handling resume

          Reply.new(text: t("komsiluk.post.web_guidance", url: komsiluk_board_url), report: nil)
        end

        # True when a multi-turn picker is possible: a session store is wired and
        # the message carries a sender id (Viber). Web chat has neither.
        def komsiluk_picker_available?(message)
          !session_store.nil? && message_sender(message).present?
        end

        # Resolve only an exact, standalone picker reply. Embedded digits and
        # category words are ordinary citizen text, never authorization.
        def parse_komsiluk_category(text)
          folded = fold(text).squish
          return nil if folded.empty?

          return KOMSILUK_CATEGORY_CHOICES[folded] if KOMSILUK_CATEGORY_CHOICES.has_key?(folded)

          KOMSILUK_CATEGORY_KEYWORDS.each do |category, keywords|
            return category if keywords.include?(folded)
          end
          nil
        end

        # e3. KOMŠILUK READ — "šta ima u komšiluku?" returns a short digest of the
        # citizen's own board, by @nickname only (same privacy as the web board:
        # never a name/address, never another komšiluk's posts).
        def komsiluk_board_reply(message)
          return nil if report_signal?(message)

          return nil unless promoted_intent?(:komsiluk_read) || komsiluk_read_intent?(fold(message.text))

          member = komsiluk_member_for(message, require_sms: false)
          if member.nil?
            if message_sender(message).blank?
              return Reply.new(
                text: t("komsiluk.read.web_guidance", board_url: komsiluk_board_url, setup_url: komsiluk_url),
                report: nil,
                quick_replies: komsiluk_read_quick_replies
              )
            end

            return Reply.new(text: t("komsiluk.read.not_member", url: komsiluk_url), report: nil,
                             quick_replies: komsiluk_read_quick_replies)
          end

          _user, profile = member
          posts = Decidim::Bih::KomsilukPost.visible
                                            .for_komsiluk(profile.komsiluk_id)
                                            .where(decidim_organization_id: organization.id)
                                            .order(created_at: :desc)
                                            .limit(KOMSILUK_DIGEST_LIMIT)
                                            .includes(:author)
          return Reply.new(text: t("komsiluk.read.empty"), report: nil) if posts.empty?

          Reply.new(text: komsiluk_digest_text(posts), report: nil)
        end

        # The resolved user's CitizenProfile when they may use the board: assigned
        # to a komšiluk, and (for writes) phone-verified. Returns [user, profile]
        # or nil. Mirrors RequiresKomsilukMembership exactly.
        def komsiluk_member_for(message, require_sms:)
          user = resolve_goodwill_user(message)
          return nil if user.nil?
          return nil if require_sms && !sms_authorized?(user)

          profile = Decidim::Bih::CitizenProfile.find_by(
            decidim_organization_id: organization.id, decidim_user_id: user.id
          )
          return nil unless profile&.assigned?

          [user, profile]
        end

        def sms_authorized?(user)
          Decidim::Authorization.find_by(user: user, name: "sms")&.granted? || false
        end

        # True for a board-READ query: the explicit board word "tabla", or a
        # neighbourhood word paired with a "what's new" cue. Deliberately strict
        # so a report mentioning the komšiluk is not swallowed as a read.
        def komsiluk_read_intent?(folded)
          return false if folded.empty?
          return true if folded.include?("tabla")

          KOMSILUK_AREA_WORDS.any? { |word| folded.include?(word) } &&
            KOMSILUK_READ_CUES.any? { |cue| folded.include?(cue) }
        end

        # Content out of "objavi [u komšiluku]: <content>" — the text after the
        # first colon. nil when no colon/content was supplied (prompts usage).
        def extract_post_content(text)
          text.to_s.split(":", 2)[1].to_s.strip.presence
        end

        # nickname-only recent-posts digest (never a name/address).
        def komsiluk_digest_text(posts)
          lines = posts.map do |post|
            category = I18n.t("decidim.bih.komsiluk_board.categories.#{post.category}",
                              locale: reply_locale, default: post.category)
            nickname = post.author&.nickname
            author = nickname.present? ? "@#{nickname}" : t("komsiluk.read.anon")
            t("komsiluk.read.item", category: category, title: post.title, author: author)
          end
          [t("komsiluk.read.header"), *lines].join("\n")
        end

        # Engine-relative komšiluk-picker path (matches contribution_url's style).
        def komsiluk_url
          Decidim::Bih::Engine.routes.url_helpers.edit_komsiluk_path
        end

        def komsiluk_board_url
          Decidim::Bih::Engine.routes.url_helpers.komsiluk_board_index_path
        end

        def account_url
          Decidim::Bih::Engine.routes.url_helpers.account_overview_path
        end

        def registration_url
          Decidim::Bih.registration_path
        end

        def verification_url
          Decidim::Bih::Engine.routes.url_helpers.verification_explainer_path
        end

        def notifications_url
          "/notifications_settings"
        end

        def report_form_url(message = nil)
          Decidim::Bih::Engine.routes.url_helpers.new_report_path(location_query_params(message))
        end

        def participation_url
          slug = Decidim::Bih.flagship_process_slug.to_s.strip
          slug.present? ? "/processes/#{slug}" : Decidim::Bih.public_path
        end

        def volunteer_url
          Decidim::Bih::Engine.routes.url_helpers.volunteer_path
        end

        # The "Zajedništvo" hub — points, rewards, invitations and the "how it
        # works" tab — where the launch answer sends citizens for full terms.
        def community_hub_url
          Decidim::Bih::Engine.routes.url_helpers.community_hub_path
        end

        def mz_directory_url
          Decidim::Bih::Engine.routes.url_helpers.mz_directory_path
        end

        def mz_area_url(area)
          Decidim::Bih::Engine.routes.url_helpers.mz_area_path(slug: area.slug)
        end

        # f. CITY EVENT QUESTION — host-wired current outage/alert store.
        def city_event_reply(message)
          return nil if city_events.nil? || report_signal?(message)

          query = promoted_query_for(:city_event)
          answer = city_events.answer(text: [message.text, query].compact_blank.join(" "), locale: reply_locale)
          return nil if answer.blank?

          Reply.new(text: answer, report: nil, quick_replies: report_quick_replies(message))
        end

        # f2. LIVE SERVICE QUESTION — host-wired current source summaries. This
        # sits before the static service directory so "kvalitet vazduha" can
        # answer with the latest measurement instead of only a source URL.
        def live_service_reply(message)
          return nil if live_service_answers.nil? || report_signal?(message)

          text = service_context_text(message, promoted_query_for(:service))
          return nil if text.blank?

          answer = live_service_answer(text:, message:)
          return nil if answer.blank?

          Reply.new(text: answer.to_s, report: nil, quick_replies: live_service_quick_replies(answer, message))
        rescue StandardError => e
          log_failure("live_service_answer_failed", e)
          nil
        end

        # g. SERVICE QUESTION (skipped when the message clearly is a report).
        def service_reply(message)
          return nil if report_signal?(message)

          text = service_context_text(message)
          return nil if text.strip.empty?

          hit = directory.search(promoted_query_for(:service) || text, limit: 1).first
          return nil unless hit

          Reply.new(text: t("service.answer", answer: hit[:answer], source: hit[:source_url]), report: nil,
                    quick_replies: service_quick_replies(message))
        end

        # Explicit classifier help. Gemini can correctly recognize general
        # capability/help questions that contain no deterministic keyword. In
        # that case answer with the help menu before the broad service-directory
        # search has a chance to over-match generic words like "šta" or "da".
        # If the text has an explicit deterministic signal, yield to the normal
        # handlers so a mistaken :help classification cannot hide a real answer.
        def help_reply(message)
          folded = fold(message.text)
          return nil unless promoted_intent?(:help) || help_intent?(folded)
          return nil if deterministic_answer_signal?(message)

          fallback_reply
        end

        # g. PROBLEM-REPORT GUIDANCE
        #
        # Text, an image, GPS or an optional classifier label can express intent
        # or provide evidence; none authorizes a write. The legacy intake cannot
        # bind a separate confirmation to actor/organization/draft revision and
        # cannot return a durable idempotency receipt, so this responder always
        # hands off to the supported report form.
        def report_reply(message)
          classifier_guidance = promoted_intent?(:report) && allow_classifier_text_report
          return nil unless report_signal?(message) || classifier_guidance

          Reply.new(
            text: t("report_guidance.answer", url: report_form_url(message)),
            report: nil,
            quick_replies: report_quick_replies(message),
            answer_intent: "report_guidance"
          )
        end

        # The Decidim::User behind this message, or nil. Delegates to the
        # host-wired resolver (Viber linkage / web current_user). Best-effort:
        # any resolver error degrades to nil (anonymous fallback), so a flaky
        # identity bridge can never break the bot. A resolved GROUP is treated as
        # no user — groups never earn recognition, so they have no personal rank.
        # A blocked or deleted account is also rejected (defence in depth): a
        # pre-existing linkage to a since-blocked account must stop conferring
        # points or report authorship even if a resolver fails to filter it.
        def resolve_goodwill_user(message)
          return nil if goodwill_user_resolver.nil?

          user = goodwill_user_resolver.call(message)
          return nil if user.nil?
          return nil if user.respond_to?(:group?) && user.group?
          return nil unless active_resolved_user?(user)

          user
        rescue StandardError => e
          log_failure("goodwill_user_resolver_failed", e)
          nil
        end

        # True unless the resolved user is provably blocked or deleted. Each check
        # is guarded by respond_to? so non-Decidim test doubles (which may not
        # implement these predicates) are treated as active, while real
        # Decidim::User accounts are rejected when blocked/deleted.
        def active_resolved_user?(user)
          return false if user.respond_to?(:blocked?) && user.blocked?
          return false if user.respond_to?(:deleted?) && user.deleted?
          return false if user.respond_to?(:active_for_authentication?) && !user.active_for_authentication?

          true
        end

        # True when the account is missing or holds no points at all (no
        # recognition and an empty wallet) — answered with the "none" nudge.
        def no_points?(account)
          account.nil? || (account.contribution_score.to_i.zero? && account.balance.to_i.zero?)
        end

        # READ-ONLY account lookup for the goodwill intent. Unlike Ledger#
        # account_for it never CREATES an account, so merely asking "koliko imam
        # bodova" can't mint an empty ledger account. Returns nil when the user
        # has no account yet.
        def goodwill_account_for(user)
          # Scope to the RESPONDER's injected organization, never the resolved
          # user's own org. Today they always match, but if a resolver ever
          # returned a foreign user this guard keeps the bot from exposing
          # another organization's goodwill account (defence in depth).
          return nil unless user.decidim_organization_id == organization.id

          Decidim::Bih::Goodwill::Account.find_by(
            decidim_organization_id: organization.id,
            owner_type: user.class.base_class.name,
            owner_id: user.id,
            kind: "user"
          )
        end

        # READ-ONLY lookups for the own-state handler, all scoped to the
        # responder's organization AND the resolved user, so another citizen's
        # rows are unreachable by construction.
        def launch_invitation_reward_key
          configured = Decidim::Bih.respond_to?(:launch_invitation_reward_key) ? Decidim::Bih.launch_invitation_reward_key : nil
          configured.presence || Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY
        end

        def launch_invitation_reward
          Decidim::Bih::Goodwill::RewardsCatalog.find(launch_invitation_reward_key, organization)
        end

        # The citizen's invitation row: a live one (reserved/requested/
        # fulfilled) wins over a canceled one, newest first within each.
        def launch_invitation_for(user)
          rows = Decidim::Bih::Goodwill::RewardFulfillment
                 .where(decidim_organization_id: organization.id, decidim_user_id: user.id, reward_key: launch_invitation_reward_key)
                 .order(created_at: :desc, id: :desc)
                 .to_a
          rows.find { |row| %w(requested reserved fulfilled).include?(row.status) } || rows.first
        end

        def citizen_profile_for(user)
          Decidim::Bih::CitizenProfile.find_by(decidim_organization_id: organization.id, decidim_user_id: user.id)
        end

        # A komšiluk/MZ name in the reply script (Latin or Cyrillic).
        def area_display_name(area)
          I18n.with_locale(reply_locale) { area.translated_name }
        rescue StandardError
          area.respond_to?(:slug) ? area.slug.to_s : ""
        end

        # g. FALLBACK / HELP
        #
        # The help reply doubles as the entry point for first-time / low-literacy
        # visitors, so it carries tappable civic-shortcut chips (report / propose
        # an idea / city budget / donate). Only THIS reply gets chips —
        # substantive answers (status, budget, waste, …) deliberately do not, so
        # the chips read as "here's where to start" rather than noise on a real
        # answer. Chip-incapable channels (Viber) just ignore the field.
        def fallback_reply
          Reply.new(text: help_text, report: nil, quick_replies: civic_shortcuts)
        end

        # The civic-shortcut chips for the help/fallback reply, in the reply
        # script (Latin or sr-Cyrl). Delegated to the shared CivicShortcuts
        # builder so the web controller's own fallback path shares the exact
        # same chip menu.
        def civic_shortcuts
          Decidim::Bih::Concierge::CivicShortcuts.new(
            organization: organization, locale: reply_locale
          ).chips
        end

        def report_quick_replies(message = nil)
          [shortcut_chip("report", report_form_url(message))].compact
        end

        def service_quick_replies(message = nil)
          report_quick_replies(message)
        end

        def live_service_quick_replies(answer, message = nil)
          quick_replies = []
          quick_replies.concat(Array(answer.quick_replies)) if answer.respond_to?(:quick_replies)
          quick_replies.concat(service_quick_replies(message))
          quick_replies.uniq { |reply| [reply[:label] || reply["label"], reply[:url] || reply["url"]] }
        end

        def komsiluk_read_quick_replies
          [
            shortcut_chip("komsiluk", komsiluk_board_url),
            shortcut_chip("setup", verification_url)
          ].compact
        end

        def shortcut_chip(key, url)
          return nil if url.blank?

          {
            label: I18n.t("decidim.bih.concierge.widget.quick.#{key}", locale: reply_locale),
            url:
          }
        end

        # --- intent helpers -------------------------------------------------

        # A photo or non-contextual location is a report-guidance signal only.
        # Web chat can attach browser coordinates as transient context for
        # "odavde/ovdje" questions; those messages implement #location_context?
        # so they do not bypass service/local-area/report-guidance answers.
        def report_signal?(message)
          message_image_url(message).present? ||
            (message_has_location?(message) && !message_location_context?(message))
        end

        def setup_intent?(folded)
          SETUP_KEYWORDS.any? { |keyword| folded.include?(keyword) } ||
            SETUP_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def help_intent?(folded)
          HELP_KEYWORDS.any? { |keyword| folded.include?(keyword) } ||
            HELP_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def feedback_help_intent?(folded)
          return false if folded.empty?

          FEEDBACK_HELP_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def report_guidance_intent?(folded)
          REPORT_GUIDANCE_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def participation_guidance_intent?(folded)
          PARTICIPATION_GUIDANCE_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def volunteer_guidance_intent?(folded)
          VOLUNTEER_GUIDANCE_KEYWORDS.any? { |keyword| folded.include?(keyword) } ||
            VOLUNTEER_GUIDANCE_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def launch_intent?(folded)
          return false if folded.empty?

          LAUNCH_KEYWORDS.any? { |keyword| folded.include?(keyword) } ||
            LAUNCH_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def data_status_intent?(folded)
          return false if folded.empty?

          DATA_STATUS_KEYWORDS.any? { |keyword| folded.include?(keyword) } ||
            DATA_STATUS_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def local_area_guidance_intent?(folded)
          LOCAL_AREA_GUIDANCE_SCOPE_WORDS.any? { |keyword| folded.include?(keyword) } ||
            LOCAL_AREA_GUIDANCE_PHRASES.any? { |phrase| folded.include?(phrase) }
        end

        def local_area_contact_intent?(folded)
          LOCAL_AREA_GUIDANCE_CONTACT_WORDS.any? { |keyword| folded.include?(keyword) }
        end

        def deterministic_answer_signal?(message)
          return true if report_signal?(message)
          return true if message.text.to_s.match?(STATUS_REFERENCE)

          folded = fold(message.text)
          return false if folded.empty?

          keyword_answer_signal?(folded) || guidance_answer_signal?(folded) ||
            feedback_help_intent?(folded) || data_status_intent?(folded) ||
            komsiluk_read_intent?(folded) || live_service_answer_signal?(message)
        end

        def keyword_answer_signal?(folded)
          [GAZETTE_KEYWORDS, BUDGET_KEYWORDS, WASTE_KEYWORDS, DONATION_KEYWORDS, GOODWILL_KEYWORDS, POST_KEYWORDS].any? do |keywords|
            keywords.any? { |keyword| folded.include?(keyword) }
          end
        end

        def guidance_answer_signal?(folded)
          setup_intent?(folded) ||
            report_guidance_intent?(folded) ||
            participation_guidance_intent?(folded) ||
            volunteer_guidance_intent?(folded) ||
            local_area_guidance_intent?(folded)
        end

        def live_service_answer_signal?(message)
          return false unless live_service_answers.respond_to?(:match?)

          live_service_answers.match?(text: service_context_text(message))
        rescue StandardError => e
          log_failure("live_service_match_failed", e)
          false
        end

        def live_service_answer(text:, message:)
          if live_service_answer_accepts_location?
            live_service_answers.answer(text:, locale: reply_locale, location: message_location_hash(message))
          else
            live_service_answers.answer(text:, locale: reply_locale)
          end
        end

        def live_service_answer_accepts_location?
          live_service_answers.method(:answer).parameters.any? do |kind, name|
            kind == :keyrest || ([:key, :keyreq].include?(kind) && name == :location)
          end
        rescue StandardError
          false
        end

        def service_context_text(message, promoted_query = nil)
          [previous_service_context(message), message.text, promoted_query].compact_blank.join(" ")
        end

        def previous_service_context(message)
          return nil unless contextual_follow_up?(message.text)

          turn = previous_conversation_turn(message)
          return nil unless turn && turn["answer_intent"].to_s == "service"

          turn["user"].to_s.strip.presence
        end

        def previous_conversation_turn(message)
          return nil unless message.respond_to?(:conversation_context)

          Array(message.conversation_context).reverse.find { |turn| turn.respond_to?(:[]) }
        end

        def contextual_follow_up?(text)
          folded = fold(text)
          return false if folded.blank?

          CONTEXT_FOLLOW_UP_CUES.any? { |cue| folded.start_with?(cue) || folded.include?(" #{cue}") }
        end

        def message_image_url(message)
          message.respond_to?(:image_url) ? message.image_url : nil
        end

        def message_has_location?(message)
          !message_coordinate(message, :latitude).nil? && !message_coordinate(message, :longitude).nil?
        end

        def message_location_context?(message)
          message.respond_to?(:location_context?) && message.location_context?
        end

        def message_location_hash(message)
          return nil unless message_has_location?(message)

          { latitude: message_coordinate(message, :latitude), longitude: message_coordinate(message, :longitude) }
        end

        def message_coordinate(message, key)
          return nil unless message.respond_to?(key)

          Float(message.public_send(key))
        rescue ArgumentError, TypeError
          nil
        end

        def location_query_params(message)
          location = message_location_hash(message)
          return {} unless location && message_location_context?(message)

          {
            lat: format("%.6f", location.fetch(:latitude)),
            lon: format("%.6f", location.fetch(:longitude))
          }
        end

        def local_area_current_location_intent?(folded)
          return false if folded.blank?

          area_word = local_area_guidance_intent?(folded) ||
                      KOMSILUK_AREA_WORDS.any? { |word| folded.include?(word) }
          area_word && LOCATION_CONTEXT_CUES.any? { |cue| folded.include?(cue) }
        end

        def local_area_location_reply(message)
          location = message_location_hash(message)
          result = Decidim::Bih::Geo::AreaLocator.new.resolve(
            lat: location.fetch(:latitude),
            lon: location.fetch(:longitude),
            organization:
          )
          areas = []
          areas << area_label_with_prefix("Komšiluk", result[:komsiluk]) if result[:komsiluk]
          areas << area_label_with_prefix("MZ", result[:mz]) if result[:mz]
          return Reply.new(text: t("local_area_guidance.location_not_found", url: komsiluk_url), report: nil) if areas.empty?

          Reply.new(
            text: t("local_area_guidance.found_by_location", areas: areas.join("; "), url: komsiluk_url),
            report: nil
          )
        rescue StandardError => e
          log_failure("local_area_location_lookup_failed", e)
          Reply.new(text: t("local_area_guidance.location_not_found", url: komsiluk_url), report: nil)
        end

        def area_label_with_prefix(prefix, area)
          name = local_area_name(area)
          return name if fold(name).start_with?(fold(prefix))

          "#{prefix} #{name}"
        end

        def find_mz_area(query)
          query_fold = fold(query)
          return nil if query_fold.empty?

          Decidim::Bih::LocalArea
            .mz
            .where(decidim_organization_id: organization.id)
            .find do |area|
            local_area_search_text(area).include?(query_fold) ||
              query_fold.include?(fold(area.slug)) ||
              local_area_name_tokens(area).any? { |token| token.length >= 4 && query_fold.include?(token) }
          end
        end

        def local_area_search_text(area)
          fold([area.slug, *area.name.values].compact.join(" "))
        end

        def local_area_name_tokens(area)
          local_area_search_text(area).split(/\s+/).reject do |token|
            token.length < 4 ||
              LOCAL_AREA_GUIDANCE_SCOPE_WORDS.include?(token) ||
              LOCAL_AREA_GUIDANCE_CONTACT_WORDS.include?(token)
          end
        end

        def local_area_name(area)
          I18n.with_locale(reply_locale) { area.translated_name }
        end

        def local_area_president(area)
          I18n.with_locale(reply_locale) do
            area.display_predsjednik.presence || t("local_area_guidance.no_contact")
          end
        end

        def promoted_intent?(intent)
          Thread.current[PROMOTED_INTENT_KEY] == intent
        end

        def promoted_query_for(intent)
          return nil unless promoted_intent?(intent)

          Thread.current[PROMOTED_QUERY_KEY].to_s.strip.presence
        end

        # Strips waste keywords + filler from the question, leaving the area.
        def waste_query(raw)
          raw.to_s.split(/\s+/).reject do |word|
            folded = fold(word).gsub(/[^a-z0-9]/, "")
            folded.empty? ||
              WASTE_KEYWORDS.any? { |keyword| folded.start_with?(keyword) } ||
              WASTE_FILLER.include?(folded)
          end.join(" ").strip
        end

        def waste_partial_coverage_gap(query)
          return nil unless waste_schedule.respond_to?(:partial_coverage_gap_for)

          gap = waste_schedule.partial_coverage_gap_for(query)
          return nil unless gap.is_a?(Hash) && Array(gap[:districts]).any?

          {
            districts: Array(gap[:districts]),
            source_url: gap[:source_url].to_s.presence || "#"
          }
        end

        def waste_reply_text(query)
          return t("waste.ask_area") if query.blank?

          days = waste_schedule.collection_days_for(query)
          return with_waste_source_note(t("waste.found", area: query, days: localize(days.join(", ")))) if days.present?
          # A place the schedule matched but could not confirm for this query
          # is a QUESTION, not an empty source. Saying "nemam podatak" here
          # would turn "which of these did you mean?" into "no such record".
          return t("waste.ask_area") if waste_lookup_unconfirmed?(query)

          gap = waste_partial_coverage_gap(query)
          return with_waste_source_note(t("waste.not_found", area: query)) unless gap

          with_waste_source_note(
            t("waste.partial_coverage", area: query, districts: localize(gap.fetch(:districts).join(", ")),
                                        source: gap.fetch(:source_url))
          )
        end

        # Hosts whose schedule can only answer +collection_days_for+ keep the
        # previous behaviour: without a resolution there is nothing to confirm.
        def waste_lookup_unconfirmed?(query)
          return false unless waste_schedule.respond_to?(:resolution_for)

          waste_schedule.resolution_for(query)[:status] == :ambiguous
        rescue StandardError
          false
        end

        def with_waste_source_note(text)
          note = waste_source_note
          return text if note.blank?

          "#{text} #{localize(note)}"
        end

        def waste_source_note
          return waste_schedule.source_note(locale: reply_locale).to_s.presence if waste_schedule.respond_to?(:source_note)

          metadata = waste_source_metadata
          return nil if metadata.values.all?(&:blank?)

          parts = []
          parts << "Izvor: #{metadata.fetch(:provider).presence || "raspored odvoza"}"
          parts << metadata.fetch(:kind) if metadata.fetch(:kind).present?
          parts << "provjereno #{formatted_source_checked_at(metadata.fetch(:checked_at))}" if metadata.fetch(:checked_at).present?
          parts << metadata.fetch(:url) if metadata.fetch(:url).present?
          "#{parts.join("; ")}."
        end

        def waste_source_metadata
          {
            provider: waste_source_value(:source_provider),
            checked_at: waste_source_value(:source_checked_at),
            kind: waste_source_value(:source_kind),
            url: waste_source_value(:source_url)
          }
        end

        def waste_source_value(method_name)
          return nil unless waste_schedule.respond_to?(method_name)

          waste_schedule.public_send(method_name)
        rescue StandardError
          nil
        end

        def formatted_source_checked_at(value)
          if value.respond_to?(:hour)
            value.in_time_zone.strftime("%d.%m.%Y. u %H:%M")
          else
            value.to_date.strftime("%d.%m.%Y.")
          end
        rescue StandardError
          value.to_s
        end

        # Strips budget keywords + filler from the question, leaving the budget
        # category (e.g. "koliko je izdvojeno za socijalni rad" -> "socijalni rad").
        def budget_category(raw)
          raw.to_s.split(/\s+/).reject do |word|
            # Fold + drop punctuation so declined/punctuated keyword forms
            # ("budžetu", "budžeta", "budžet?") are stripped, not leaked into the
            # category — detection matches keywords as a stem, so must removal.
            folded = fold(word).gsub(/[^a-z0-9]/, "")
            folded.empty? ||
              BUDGET_KEYWORDS.any? { |keyword| folded.start_with?(keyword) } ||
              BUDGET_FILLER.include?(folded)
          end.join(" ").strip
        end

        # Lowercases, transliterates Cyrillic -> Latin, then folds Serbian Latin
        # diacritics — so keyword matching is script- and accent-insensitive and
        # a Cyrillic (sr-Cyrl) message reaches the same intents as a Latin one.
        # Delegates to the shared Decidim::Bih::Text.fold helper.
        def fold(text)
          Decidim::Bih::Text.fold(text)
        end

        # --- reply text (engine i18n, decidim.bih.concierge.*) --------------

        def status_found_text(report)
          name = Decidim::Bih::ReportStatusPresenter.label(report, locale: reply_locale)
          t("status.found", reference: report.reference, status: name)
        end

        def status_not_found_text(reference)
          t("status.not_found", reference: reference)
        end

        def help_text
          t("help")
        end

        # The citizen's position on the public leaderboard. A seam of its own so
        # the channel-agnostic brain can be exercised without ActiveRecord.
        def goodwill_rank_for(account)
          Decidim::Bih::Goodwill::Account.rank_for(account)
        end

        # The personal-goodwill summary line: balance + level title + rank (+ how
        # many points to the next level, when not yet at the top). Level titles
        # render in the reply locale (Latin or Cyrillic), matching the rest of the
        # concierge reply.
        def goodwill_found_text(account, level, rank)
          title = I18n.t("decidim.bih.goodwill.levels.#{level.key}", locale: reply_locale)
          to_next = level.points_to_next
          url = contribution_url
          suffix = rank.nil? ? "_unranked" : ""

          if to_next.nil? || to_next.zero?
            t("goodwill.found_top#{suffix}", balance: account.balance, level: title, rank: rank, url: url)
          else
            t("goodwill.found#{suffix}", balance: account.balance, level: title, rank: rank, to_next: to_next, url: url)
          end
        end

        def data_status_answer
          text =
            if data_status.respond_to?(:answer)
              data_status.answer(locale: reply_locale)
            elsif data_status.respond_to?(:call)
              data_status.call(locale: reply_locale)
            end

          text.to_s.strip.presence || data_status_unavailable_text
        rescue StandardError => e
          log_failure("data_status_provider_failed", e)
          data_status_unavailable_text
        end

        # Provider and adapter exception messages may contain citizen text,
        # locations, credentials or response bodies. Preserve a stable failure
        # code and the exception class for operations without logging the raw
        # message at this privacy boundary.
        def log_failure(code, error)
          Rails.logger.warn("[Concierge] #{code}#{" error_class=#{error.class.name}" if error}")
        end

        def data_status_unavailable_text
          localize(
            t("data_status.unavailable",
              default: "Trenutno ne mogu provjeriti status izvora podataka. Probaj ponovo malo kasnije.")
          )
        end

        # Absolute path to the public "Moj doprinos" (wallet) page — where the
        # citizen sees their full points breakdown and the verify/link CTA.
        def contribution_url
          Decidim::Bih::Engine.routes.url_helpers.wallet_path
        end

        # Decidim's own sign-in page; on phone-first hosts the page itself
        # offers the phone login, so the concierge only ever links here.
        def sign_in_url
          Decidim::Core::Engine.routes.url_helpers.new_user_session_path(locale: I18n.locale)
        rescue StandardError
          "/#{I18n.locale}/users/sign_in"
        end

        # The public points rules page (the single place the schedule is quoted).
        def rules_url
          Decidim::Bih.public_path(GoodwillEarningAnswer::RULES_PATH)
        end

        # Shared dialogue copy (decidim.bih.dialogue.*) in the reply locale, so
        # the hand-offs read the same in chat whichever brain answered.
        def dialogue_t(key, **)
          I18n.t("decidim.bih.dialogue.#{key}", locale: reply_locale, **)
        end

        # "%{count} bod/boda/bodova" from the goodwill schedule's own plural key.
        def points(count)
          t("goodwill.earning.points", count: count.to_i)
        end

        # Looks up a concierge reply string in the current reply locale (Serbian
        # Latin by default, sr-Cyrl for a Cyrillic-script citizen).
        def t(key, **)
          I18n.t("decidim.bih.concierge.#{key}", locale: reply_locale, **)
        end

        # The locale chosen for THIS reply (set in #respond), defaulting to Latin.
        def reply_locale
          Thread.current[REPLY_LOCALE_KEY] || LOCALE
        end

        # Reply in Cyrillic when the inbound message is predominantly Cyrillic,
        # else Latin. Messages with no letters (photo-/location-only) default to
        # Latin — there is no script signal to honour.
        def detect_reply_locale(message)
          text = message.respond_to?(:text) ? message.text.to_s : ""
          cyrillic = text.scan(/\p{Cyrillic}/).size
          latin = text.scan(/[A-Za-z]/).size
          cyrillic > latin ? CYRILLIC_LOCALE : LOCALE
        end

        # Transliterate human-readable Latin content (e.g. canonical day names)
        # into the reply script. NEVER pass identifiers through this — report
        # references (BR-…) and URLs must stay Latin.
        def localize(text)
          reply_locale == CYRILLIC_LOCALE ? Decidim::Bih::Transliterator.call(text.to_s) : text
        end
      end
    end
  end
end

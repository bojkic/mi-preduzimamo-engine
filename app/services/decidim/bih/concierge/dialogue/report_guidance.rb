# frozen_string_literal: true

require "i18n"
require_relative "contracts"
require_relative "own_report_question"
require_relative "resolution"
require_relative "procedure_runner"
# The seam this file registers into. Circular by design and safe: by the time
# pre_model_stages requires this file back, its module and +register+ exist.
require_relative "pre_model_stages"
require_relative "../responder"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Reviewed answers to the questions citizens ask ABOUT a report, as
        # opposed to the report itself: who sees it, whether it can be
        # anonymous, what the map shows, the photo, duplicates and
        # corroboration, where their own reports are, how long resolution
        # takes, and what "forwarded" actually means.
        #
        # == Why these are deterministic
        #
        # Every one of these is already written down and reviewed — most of it
        # on the report form, in the "Ko šta vidi?" box the citizen reads while
        # filing. The rated corpus shows the platform holding the answer and
        # never reaching it: "Ko vidi moju prijavu?" was refused, and the report
        # preview two turns later printed the visibility rules verbatim. Three
        # sessions (b3c19–b3c22) got the Sistem 48 aggregate listing or "za ovu
        # temu još nemam provjeren izvor" instead.
        #
        # These questions arrive under whatever topic the model guessed, which
        # is why they are a pre-model STAGE rather than a procedure branch.
        #
        # == What it does not do
        #
        # It starts no task and writes no TASK state, performs no read and
        # makes no model call, so an unfinished report draft survives one of
        # these answers untouched and every card answers identically with the
        # provider down. Safety is decided by Coordinator.control_reply before
        # any stage runs, so an emergency keeps precedence over every card here
        # by construction.
        #
        # What it does record is WHAT IT ANSWERED, in the separate
        # +AnswerContext+ slot — the same thing +PublicInformationStage+ does,
        # and for the same reason. Without it a "kraće" after one of these
        # cards had nothing to attach to and was re-classified from scratch
        # (case r9c02). See ReportGuidanceStage#retained.
        #
        # == What it must never say
        #
        # A resolution DEADLINE. "Sistem 48" is the city's promise to ANSWER
        # within 48 hours; nothing on this platform promises a repair date, and
        # the only SLA constants in the code are internal operator triage
        # thresholds. An invented deadline is the one failure mode that would
        # be worse than the refusal it replaces.
        module ReportGuidance
          MAX_LENGTH = 200

          Card = Data.define(:name, :answer_intent)

          LINK = Card.new(name: "report_form_link", answer_intent: "report_guidance")
          HOW_TO = Card.new(name: "report_how_to", answer_intent: "report_guidance")
          GUIDANCE_ONLY = Card.new(name: "report_guidance_only", answer_intent: "report_guidance")
          SISTEM48 = Card.new(name: "report_sistem48_overview", answer_intent: "report_guidance")
          COMPARISON = Card.new(name: "report_sistem48_comparison", answer_intent: "report_guidance")
          RESPONSIBILITY = Card.new(name: "report_responsibility", answer_intent: "report_guidance")
          VISIBILITY = Card.new(name: "report_visibility", answer_intent: "report_guidance")
          ADDRESS_PRIVACY = Card.new(name: "report_address_privacy", answer_intent: "report_guidance")
          ANONYMITY = Card.new(name: "report_anonymity", answer_intent: "report_guidance")
          PHOTO = Card.new(name: "report_photo", answer_intent: "report_guidance")
          DUPLICATE = Card.new(name: "report_duplicate", answer_intent: "report_guidance")
          FORWARDING = Card.new(name: "report_forwarding", answer_intent: "report_guidance")
          RESOLUTION_TIME = Card.new(name: "report_resolution_time", answer_intent: "report_guidance")
          OWN_RECOVERY = Card.new(name: "report_own_recovery", answer_intent: "status")
          OWN = Card.new(name: "report_own", answer_intent: "status")
          PUBLIC_MAP = Card.new(name: "report_public_map", answer_intent: "report_guidance")
          SCOPE = Card.new(name: "report_scope", answer_intent: "report_guidance")
          LIMITS = Card.new(name: "report_limits", answer_intent: "report_guidance")

          # "Prijava" is also the word for signing IN. An account sentence is
          # never a report question, whatever else it contains.
          ACCOUNT_CONTEXT = /(?:na\s+(?:moj\s+|svoj\s+)?(?:nalog|racun)|lozink\w*|registracij\w*|se\s+prijavim|prijaviti\s+se|sign\s+in|password)/
          # The points framing of a cap belongs to the goodwill rules, not here.
          POINTS_WORD = /(?:bodov\w*|poen\w*)/

          VISIBILITY_CUE = /(?:ko\s+(?:sve\s+)?(?:vidi|moze\s+(?:da\s+)?(?:vidi|vidjeti))|ko\s+ce\s+vid\w*
                             |je\s+li\s+(?:moja\s+)?prijava\s+javna|da\s+li\s+je\s+(?:moja\s+)?prijava\s+javna
                             |javna\s+(?:na\s+)?(?:kart[aiu]|map[aiu])|samo\s+administracij\w*|vidi\s+li\s+(?:je\s+)?samo
                             |sta\s+je\s+javno|sta\s+se\s+vidi|who\s+sees)/x
          REPORT_WORD = /(?:prijav\w*|problem\w*)/
          ANONYMOUS = /anonimn\w*/
          ADDRESS_WORD = /(?:adres\w*|kucn\w*\s+adres\w*|gdje\s+zivim|gde\s+zivim|address)/
          PHOTO_WORD = /(?:fotografij\w*|slik[auei]\b|slike\b|fotk\w*|photo|picture)/
          PHOTO_CUE = /(?:uz\s+prijavu|poslati|posalj\w*|dodat\w*|priloz\w*|prikac\w*|obrazac|mogu\s+li|kako\s+da|upload)/
          DUPLICATE_CUE = /(?:vec\s+(?:je\s+)?prijav\w*|vec\s+prijavljen\w*|isti\s+problem|duplikat\w*
                            |neko\s+je\s+(?:vec\s+)?(?:prijavio|prijavila|prijavio\s+isto)|tudj[ue]\s+prijav\w*
                            |potvrd\w*\s+tudj\w*|i\s+mene\s+pogadja|already\s+reported)/x
          # "Prosljeđivanje" names one thing on this platform, so it needs no
          # second anchor; the weaker phrasings do.
          FORWARDING_STRONG = /(?:proslje[dj]\w*|prosle[dj]\w*|forwarded)/
          FORWARDING_CUE = /(?:poslat[ao]?\s+(?:gradu|sluzbi|opstini)|ide\s+li\s+gradu
                             |dobija\s+status\s+da\s+je\s+poslat|prihvac\w*)/x
          # Naming Sistem 48 is not asking what its 48 hours mean: "prikazi
          # javne podatke za sistem48" is a READ, and taking it here would
          # replace the city's own listing with a card about deadlines.
          SLA_SUBJECT = /(?:sistem\s*48|48\s*(?:sat\w*|h\b))/
          SLA_CLAIM = /(?:znaci|sigurn\w*|garant\w*|obavez\w*|popravlj\w*|rijes\w*|rjesav\w*|obecanj\w*|\brok\b|zaista|stvarno|da\s+li)/
          RESOLUTION_CUE = /(?:kada\s+ce\s+(?:biti\s+)?(?:popravlj\w*|rijes\w*|sredj\w*)
                            |koliko\s+(?:dugo\s+)?(?:se\s+)?(?:ceka|traje)|rok\s+za\s+(?:rjesavanj\w*|popravk\w*)
                            |razlik[au]\s+izmedju\s+odgovora\s+i\s+rjesavanj\w*|odgovora\s+i\s+rjesavanj\w*)/x
          OWN_CUE = /(?:(?:gdje|gde)\s+(?:su|se\s+nalaze)\s+moje\s+prijav\w*|moje\s+prijave\s+nakon
                      |(?:gdje|gde)\s+vidim\s+svoje\s+prijav\w*|(?:gdje|gde)\s+su\s+mi\s+prijav\w*
                      |nemam\s+oznaku|nemam\s+broj\s+prijav\w*|izgubio\s+sam\s+broj\s+prijav\w*|my\s+reports)/x
          PUBLIC_MAP_CUE = /(?:javn\w*\s+(?:kart\w*|map\w*)|(?:kart[au]|map[au])\s+(?:svih\s+)?(?:prijav\w*|prijavljen\w*|problem\w*)
                             |(?:gdje|gde)\s+(?:mogu\s+)?(?:da\s+)?(?:pogledam|vidim|pregledam)\s+(?:sve\s+)?(?:javn\w*\s+)?(?:prijav\w*|kart\w*|map\w*)
                             |spisak\s+prijav\w*|sve\s+prijave)/x
          SCOPE_CUE = /(?:komsij\w*|susjed\w*|\bspor\b|svadj\w*|privatn\w*|imovinsk\w*|prijetnj\w*|kradj\w*)/
          NOISE = /(?:buk[aeiu]\b|galam\w*|glasn\w*\s+muzik\w*|noise)/
          LIMITS_CUE = /(?:sest[au]\s+prijav\w*|previse\s+prijav\w*|dnevn\w*\s+(?:granic\w*|limit\w*|ogranicenj\w*)
                         |limit\s+prijav\w*|ogranicen\s+broj\s+prijav\w*|bit[i]?\s+odbijen\w*\s+zbog|odbijena\s+zbog)/x

          module_function

          # The card this utterance asks for, or nil. +actor_id+ is used for one
          # decision only: a SIGNED-IN citizen asking where their reports are
          # gets the real scoped read instead of this guidance card.
          def card(text, actor_id: nil)
            return unless text.is_a?(String)

            stripped = text.strip
            return unless stripped.length.between?(1, MAX_LENGTH)

            query = Decidim::Bih::Text.fold(stripped)
            return if query.empty?
            # "Gdje se nalaze moje prijave nakon prijave na nalog?" names an
            # account AND asks a report question. The own-report shape is
            # specific enough to answer before the account veto applies.
            return OWN if actor_id.nil? && (OWN_CUE.match?(query) || /\A(?:gdje|gde)\s+su\s+moja\s+prijavljena\s+ostecenja\z/.match?(query))
            return if ACCOUNT_CONTEXT.match?(query)

            card_for(query)
          end

          # THE RULE SET IS THE ORDER: [card, matcher], first match wins.
          # Anonymity comes before visibility because "da li anonimno znači da
          # se ni moja adresa ne vidi" is a question about the citizen's own
          # address, not about what a report publishes.
          CARD_RULES = [
            [COMPARISON, ->(query) { /razlik|uporedi|usporedi/.match?(query) && /sistem\s*48/.match?(query) && /\bmi\b/.match?(query) }],
            [GUIDANCE_ONLY, ->(query) { /odgovor\s+milic\w*/.match?(query) && /poslat\w*\s+prijav|salje\s+prijav/.match?(query) }],
            [RESPONSIBILITY, ->(query) { /ko\s+je\s+(?:odgovoran|nadlezan)|nadleznost/.match?(query) && REPORT_WORD.match?(query) }],
            [ANONYMITY, ->(query) { ANONYMOUS.match?(query) && !ADDRESS_WORD.match?(query) }],
            [ADDRESS_PRIVACY, ->(query) { ANONYMOUS.match?(query) && ADDRESS_WORD.match?(query) }],
            [VISIBILITY, ->(query) { visibility?(query) }],
            [PHOTO, ->(query) { PHOTO_WORD.match?(query) && PHOTO_CUE.match?(query) }],
            [DUPLICATE, ->(query) { DUPLICATE_CUE.match?(query) }],
            # FORWARDING first: "prosljeđuje" says exactly which card is wanted,
            # and it was losing to RESOLUTION_CUE's generic duration wording -
            # so "Da li se moja prijava prosljeđuje u Sistem 48?" was answered
            # "Ne.", the opposite of this engine's own report_forwarding copy.
            [FORWARDING, lambda { |query|
              FORWARDING_STRONG.match?(query) || (FORWARDING_CUE.match?(query) && REPORT_WORD.match?(query))
            }],
            # "koliko traje" alone is not a report question - it also asks how
            # long the verification link lasts, which belongs to the account
            # classifier. Require a report subject before claiming the turn.
            [RESOLUTION_TIME, lambda { |query|
              (RESOLUTION_CUE.match?(query) && REPORT_WORD.match?(query)) ||
                (SLA_SUBJECT.match?(query) && SLA_CLAIM.match?(query))
            }],
            [PUBLIC_MAP, ->(query) { PUBLIC_MAP_CUE.match?(query) && REPORT_WORD.match?(query) }],
            [SCOPE, ->(query) { scope?(query) }],
            [LIMITS, ->(query) { LIMITS_CUE.match?(query) && !POINTS_WORD.match?(query) }],
            [SISTEM48, ->(query) { /\A(?:sta\s+je|cemu\s+sluzi|what\s+is)\s+sistem\s*48\z/.match?(query) }],
            [HOW_TO, ->(query) { how_to?(query) }]
          ].freeze

          # A channel introduction or a topic switch may precede the question.
          # Judge the requested report subject, not a phone named in the preface.
          def how_to?(query)
            question = /\b(?:kako|gdje|gde|kome)\s+(?:da\s+)?(?:prijavim|prijaviti|prijavljujem|podnesem\s+prijavu)\b/.match(query)
            if question
              prefix = question.pre_match.sub(/\bne\s+znam\b/, "")
              return false if /\b(?:znam|znamo|objasnili|objasnio|objasnila|ne\s+pitam|ne\s+trazim|ne\s+objasnjavaj|nemoj\s+objasnjavati)\b/.match?(prefix)

              report_subject?(question.post_match)
            else
              question = /(?:\A|\b)(?:zelim|hocu)\s+(?:da\s+)?prijavim\s+(.+?)\s+kako(?:\s+da\s+to\s+uradim)?\z/.match(query)
              question && report_subject?(question[1])
            end
          end

          def report_subject?(subject)
            /(?:problem|rupu|rupe|smece|otpad|rasvjet|rasvet|ostecen|kontejner)/.match?(subject) &&
              !/(?:telefon|racunar|laptop|mobitel|aplikacij|password|lozink|\b(?:ali|nego|kada|koliko)\b)/.match?(subject)
          end

          def card_for(query)
            CARD_RULES.find { |(_, rule)| rule.call(query) }&.first
          end

          # The visibility question, including the bare follow-up that names the
          # two fields and nothing else ("Pitam baš za adresu i fotografiju, ne
          # za moje ime") — an account has neither, so the pair is unambiguous.
          def visibility?(query)
            return true if ADDRESS_WORD.match?(query) && PHOTO_WORD.match?(query)

            VISIBILITY_CUE.match?(query) && REPORT_WORD.match?(query)
          end

          # A dispute with a neighbour is not a civic service request — but
          # noise from a building site or a bar is, and must not be swept into
          # the same refusal.
          def scope?(query)
            return false unless REPORT_WORD.match?(query) || NOISE.match?(query)

            SCOPE_CUE.match?(query)
          end

          # The rendered copy for a card. The visibility card is COMPOSED from
          # the reviewed "Ko šta vidi?" box on the report form itself, so the
          # two can never drift apart; everything else is dialogue copy.
          def answer(card, locale:)
            case card.name
            when "report_how_to"
              I18n.t("decidim.bih.concierge.report_guidance.answer", locale:, url: new_report_url)
            when "report_visibility"
              t("report_visibility", locale:, public: form_copy("public", locale:), private: form_copy("private", locale:), url: reports_url)
            when "report_own", "report_own_recovery" then t(card.name, locale:, url: recover_url)
            when "report_public_map" then t("report_public_map", locale:, list: reports_url, map: map_url)
            when "report_duplicate" then t("report_duplicate", locale:, url: reports_url)
            when "report_forwarding", "report_resolution_time", "report_sistem48_overview", "report_sistem48_comparison", "report_responsibility" then t(card.name, locale:, url: reports_url)
            else t(card.name, locale:, url: new_report_url)
            end
          end

          def form_copy(key, locale:)
            I18n.t("decidim.bih.reports.new.visibility.#{key}", locale:, default: "")
          end

          def t(key, locale:, **values)
            I18n.t("decidim.bih.dialogue.#{key}", locale:, **values)
          end

          def new_report_url = engine_path(:new_report_path, "prijave/new")

          def reports_url = engine_path(:reports_path, "prijave")

          def map_url = engine_path(:reports_map_path, "mapa")

          def recover_url = engine_path(:recover_report_path, "prijave-pronadji")

          def engine_path(helper, suffix)
            Decidim::Bih::Engine.routes.url_helpers.public_send(helper)
          rescue StandardError
            hub_path(suffix)
          end

          def hub_path(suffix)
            Decidim::Bih.public_path(suffix)
          rescue StandardError
            "/biceriseno/#{suffix}"
          end
        end

        # Registers the report explanations as a pre-model stage, immediately
        # after Task 3b's public-information cards: safety and the civic
        # invariants keep precedence, and these still run BEFORE the retained
        # source follow-ups that answered "Da li moja prijava automatski dobija
        # status da je poslata gradu?" with the Sistem 48 aggregate listing.
        module ReportGuidanceStage
          module_function

          def result_for(turn)
            return if evidence_message?(turn.message)
            # A citizen who is mid-report owns the turn: a half-written draft or
            # a pending description must never be answered with a card.
            return if turn.state["draft"] || turn.state["pending_slot"] == "description"

            card = own_report_follow_up(turn) || ReportGuidance.card(turn.text, actor_id: turn.context.actor_id) || procedure_follow_up(turn) || responsibility_follow_up(turn) || link_follow_up(turn) || submission_follow_up(turn)
            return if card.nil?

            locale = locale_for(turn)
            text = ReportGuidance.answer(card, locale:)
            return if text.nil? || text.strip.empty?

            reply = Responder::Reply.new(text:, report: nil, answer_intent: card.answer_intent, tone: "core")
            ProcedureRunner::Result.new(state: retained(turn, card), reply:, resolution: Resolution::ANSWERED,
                                        fact_ids: [], handoff_offered: false, handoff_completed: false)
          end

          def procedure_follow_up(turn)
            return unless /\A(?:(?:to|ovo)\s+je\s+)?(?:pitanje\s+o\s+postupku|(?:samo\s+)?pitam\s+o\s+postupku)\z/.match?(Text.fold(turn.text))

            retained = AnswerContext.normalize(turn.state[AnswerContext::KEY], now: turn.context.now,
                                               state_expires_at: turn.state["expires_at"])
            ReportGuidance::HOW_TO if retained && retained.values_at("kind", "subject") == %w(report_card report_how_to)
          end

          def own_report_follow_up(turn)
            return unless turn.context.actor_id.nil? && (OwnReportQuestion.correction?(turn.text) || OwnReportQuestion.reference_missing?(turn.text))

            retained = AnswerContext.normalize(turn.state[AnswerContext::KEY], now: turn.context.now,
                                                 state_expires_at: turn.state["expires_at"])
            owns_report = retained && retained["kind"] == "report_card" && %w(report_own report_own_recovery).include?(retained["subject"])
            return unless owns_report || turn.state["active_task"] == "report_status"

            ReportGuidance::OWN_RECOVERY
          end

          def responsibility_follow_up(turn)
            retained = AnswerContext.normalize(turn.state[AnswerContext::KEY], now: turn.context.now,
                                                                               state_expires_at: turn.state["expires_at"])
            return unless retained && retained["kind"] == "report_card"
            return unless %w(report_how_to report_responsibility report_sistem48_comparison).include?(retained["subject"])

            query = Decidim::Bih::Text.fold(turn.text)
            return ReportGuidance::RESPONSIBILITY if /\A(?:ne\s+salji\s+nista\s+)?zanima\s+me\s+nadleznost\z|\Anemoj\s+obecati\s+datum\s+odgovora\z/.match?(query)
          end

          # The link request can refer only to the immediately retained public
          # form instructions; it cannot create or retrieve a citizen report.
          def link_follow_up(turn)
            return unless turn.text.length <= 160
            return unless retained_form_instructions?(turn)

            query = Decidim::Bih::Text.fold(turn.text).sub(/\Ane\s+vidim\s+dugme(?:\s+koje\s+pominjes)?\s+/, "")
            return unless /\A(?:(?:mozes|mozete)\s+li\s+(?:mi\s+)?(?:poslati|dati)|(?:daj|posalji)(?:\s+mi)?)\s+
              (?:direktan\s+)?link(?:\s+koji\s+mogu\s+otvoriti)?
              (?:\s+(?:iz|u|preko)\s+(?:messengera|messengeru|vibera|viberu|instagrama|instagramu|whatsappa|whatsappu))?\z/x.match?(query)

            ReportGuidance::LINK
          end

          # A link is guidance, never proof that a report was submitted. Only
          # the immediately retained form explanation can own this follow-up;
          # questions about an identified report still reach the receipt path.
          def submission_follow_up(turn)
            return unless turn.text.length <= 180 && retained_form_instructions?(turn)

            query = Decidim::Bih::Text.fold(turn.text)
            return unless /\A(?:(?:da\s+li\s+si|jesi\s+li)(?:\s+vec)?\s+(?:poslala|poslao|podnijela|podnela|podnio)\s+
              (?:moju\s+)?prijavu(?:\s+gradu)?(?:\s+ili\s+moram\s+(?:jos\s+)?nesto\s+uraditi)?|
              have\s+you(?:\s+already)?\s+(?:sent|submitted)\s+(?:my|the)\s+report(?:\s+to\s+the\s+city)?)\z/x.match?(query)

            ReportGuidance::GUIDANCE_ONLY
          end

          def retained_form_instructions?(turn)
            return false unless [nil, "ask_information", "help"].include?(turn.state["active_task"])

            retained = AnswerContext.normalize(turn.state[AnswerContext::KEY], now: turn.context.now,
                                                                               state_expires_at: turn.state["expires_at"])
            retained && retained["kind"] == "report_card" && %w(report_how_to report_form_link).include?(retained["subject"])
          end

          # The TASK state is still untouched — see "What it does not do" above.
          # What is recorded is WHAT WAS ANSWERED, in the separate AnswerContext
          # slot: the reviewed card's name and the citizen's own words for the
          # question. Nothing about the citizen's own report goes in, and
          # nothing can: a card kind may carry no action/topic at all, so the
          # private families AnswerContext refuses cannot be smuggled through
          # one. Without this a "kraće" after a report card had no subject to
          # land on and was classified from scratch (case r9c02).
          #
          # Best effort, exactly as the public card's retention is: a refused
          # CAS loses the continuity hint and keeps the answer the citizen
          # already read.
          def retained(turn, card)
            turn.retain_answer(kind: "report_card", subject: card.name, anchor: turn.text)
          end

          def evidence_message?(message)
            return true if message.respond_to?(:image_url) && !message.image_url.nil?

            message.respond_to?(:latitude) && !message.latitude.nil?
          end

          def locale_for(turn)
            return "sr-Cyrl" if turn.text.match?(/\p{Cyrillic}/)

            saved = turn.state["locale"]
            Contracts::LOCALES.include?(saved) ? saved : "sr"
          end
        end

        PreModelStages.register("report_guidance_card", after: "public_information_card") do |turn|
          ReportGuidanceStage.result_for(turn)
        end
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../../text"
require_relative "deterministic_routes"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Deterministic selection for the question the whole points economy
        # rests on: WHAT the bodovi zajedništva are and HOW they are earned —
        # as opposed to what they can be exchanged for, and as opposed to how
        # many of them this citizen has.
        #
        # == Why this is deterministic
        #
        # "Šta su bodovi zajedništva?" was left to the understanding call, and
        # the model had no route to offer it: it classified the turn as
        # +rewards+ or +community+, both CORE topics, so the catalogue reader
        # and the partner-organisation directory answered instead. Measured on
        # production on 14.09.2026, the two-turn sequence
        #
        #   1. "Šta su bodovi zajedništva?"
        #   2. "Ne tražim nagrade, nego objašnjenje bodova."
        #
        # returned the 401-character rewards catalogue in 5 of 9 sends and the
        # 1.298-character partner directory in the other 4 — and the directory
        # entry carries the foundation's published donation account and IBAN.
        #
        # The account number is not a leak; it is legitimately on the
        # foundation's own public profile. The defect is the ROUTING. Goodwill
        # points are walled off from money and from the binding vote, and a
        # donation account arriving as the answer to "explain the points to me"
        # tells the citizen the opposite: that points are something you buy.
        # Selecting the read here removes the model's opportunity to make that
        # substitution at all, rather than hoping a prompt discourages it.
        #
        # == What it selects
        #
        # The same read the +earning+ route selects — goodwill / category
        # "earn" — so the Responder answers from
        # GoodwillEarningAnswer, i.e. from the ONE effective schedule
        # (defaults → host initializer → per-organization Setting) and with the
        # reviewed "points are recognition, not power" line and the public
        # rules page. No number is typed here or there.
        #
        # == Where it sits in the order
        #
        # Last. Every existing route keeps its precedence, which is what keeps
        # the distinctions the corpus proves matter:
        #
        #   * +earning+ still owns "kako da zaradim bodove";
        #   * +goodwill_balance+ still owns "koliko imam bodova" — a citizen
        #     asking for their own number is not asking for a definition;
        #   * +goodwill_daily_cap+, +goodwill_referral+ and +reward_price+
        #     still own their narrower questions;
        #   * +launch_topic+ still pins "koliko bodova košta pozivnica" to the
        #     launch policy.
        #
        # == What it deliberately declines
        #
        # An EXCHANGE question ("šta mogu dobiti za bodove", "koje nagrade
        # imate") is about the catalogue and keeps reaching it. What points
        # ARE and what they BUY are two different questions with two different
        # reviewed answers, and answering the first with the second is half of
        # the defect this route exists to fix.
        module PointsExplainerRoute
          # "bod" on its own is spelled out rather than folded into bodov\w*
          # so that it never matches inside an unrelated word. English is here
          # for the same reason the balance route carries "my points": the
          # contract speaks +en+, and an English question deserves the same
          # reviewed answer rather than the model's guess at a topic.
          POINTS = /(?:bodov\w*|poen\w*|bodovanj\w*|\bbod\b|\bpoints?\b)/
          # The subject as a citizen names it, optionally qualified.
          SUBJECT = /(?:(?:sistem|sistemu|sistema|koncept|koncepta|pojam|pojma)\s+(?:bodov\w*|poen\w*)|#{POINTS.source})/

          # "Šta su bodovi?" — the definition, in the shapes the rated corpus
          # and its held-out paraphrases actually use.
          DEFINITION = /(?:sta\s+(?:su|je)\s+(?:to\s+)?(?:ti\s+|ovi\s+|te\s+|tvoji\s+|vasi\s+|neki\s+|ovi\s+tvoji\s+)?#{SUBJECT.source}
                         |sta\s+(?:znace|znaci|predstavljaju|predstavlja)\s+(?:ti\s+|ovi\s+|te\s+)?#{POINTS.source}
                         |what\s+(?:are|is)\s+(?:the\s+)?(?:community\s+)?points)/x

          # "Čemu služe bodovi?" — the purpose, which is the other half of
          # "what are they" and the half the vote-integrity note answers.
          PURPOSE = /(?:(?:cemu|zasto|cemu\s+uopste|zbog\s+cega)\s+(?:\w+\s+){0,2}?#{POINTS.source}
                      |sta\s+ce\s+mi\s+#{POINTS.source}
                      |(?:svrha|svrhu|smisao|smisla|poenta|poente)\s+(?:\w+\s+){0,2}?(?:bodova|poena|bodovanja))/x

          # "Objasni mi bodove" / "objašnjenje bodova" — an explicit request to
          # be told about the subject. Matched as a phrase rather than anchored
          # to the whole utterance, because the corrective turn that reproduced
          # the defect ("Ne tražim nagrade, nego objašnjenje bodova.") carries
          # the request in its second clause with no sentence punctuation to
          # split on. The cue and the subject must still be within three words
          # of each other, so an explanation of something else that happens to
          # mention points later in the message does not match.
          EXPLAIN = /(?:objasn\w*|pojasn\w*|razjasn\w*|(?:reci|kazi|pricaj|ispricaj)\s+mi\s+(?:nesto\s+)?o
                      |(?:vise|detaljnije|ukratko)\s+o|explain)
                     \s+(?:\w+\s+){0,3}?#{SUBJECT.source}/x

          # "Kako funkcionišu bodovi?" — the mechanics. The +earning+ route
          # already owns a fixed list of these phrases exactly; this widens the
          # same question to its qualified forms ("kako funkcionišu bodovi
          # zajedništva", "kako radi sistem bodova"), which that list misses.
          MECHANICS = /kako\s+(?:\w+\s+){0,2}?(?:funkcionis\w*|funkcionir\w*|rade|radi|se\s+racunaju|se\s+racuna|se\s+boduje|se\s+dodjeljuju|se\s+dodeljuju)
                       \s+(?:\w+\s+){0,2}?#{SUBJECT.source}
                       |how\s+do\s+(?:the\s+)?points\s+work/x

          # The catalogue's question, never this route's. A citizen asking what
          # points BUY is asking about the rewards catalogue, which answers it.
          EXCHANGE = /(?:sta\s+(?:sve\s+)?mogu\s+(?:da\s+)?(?:dobi\w*|kupi\w*|uze\w*|izabrati|biram|zamijeniti|zameniti)
                       |za\s+(?:sta|shta)\s+(?:mogu|sluze|mi\s+trebaju)\s+(?:\w+\s+){0,2}?#{POINTS.source}
                       |(?:potros\w*|zamijen\w*|zamen\w*|razmijen\w*|razmen\w*|iskorist\w*)\s+(?:\w+\s+){0,2}?#{POINTS.source}
                       |(?:koje|kakve|kakav|koji)\s+(?:sve\s+)?(?:nagrad\w*|poklon\w*)
                       |katalog\w*\s+nagrad|spisak\s+nagrad|lista\s+nagrad)/x

          # The whole utterance this route will read. CivicQuestion already
          # bounds the message at 160; this is the same bound the reviewed
          # public-information cards use, for the same reason: anything longer
          # is prose, a paste or a report, not a definition question.
          MAX_LENGTH = 160

          module_function

          # True when the citizen is asking what the points ARE, what they are
          # FOR, or how they WORK — and is not asking what they buy.
          def explanation?(query, text)
            return false unless text.to_s.length <= MAX_LENGTH
            return false if query.empty? || EXCHANGE.match?(query)
            return false if /\A(?:ne|nemoj)\s+(?:objasni|objasnjavati)\b/.match?(query)
            return false unless POINTS.match?(query)

            DEFINITION.match?(query) || PURPOSE.match?(query) || EXPLAIN.match?(query) || MECHANICS.match?(query)
          end
        end

        # Registered LAST, so every existing route keeps its precedence. The
        # read is the +earning+ read: the effective schedule, the "recognition,
        # not power" line and the public rules page — never the catalogue and
        # never the partner directory.
        DeterministicRoutes.register("points_explainer") do |query, text|
          { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "earn" } } if PointsExplainerRoute.explanation?(query, text)
        end
      end
    end
  end
end

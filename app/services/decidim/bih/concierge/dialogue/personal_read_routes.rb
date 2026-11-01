# frozen_string_literal: true

require_relative "../../text"
require_relative "deterministic_routes"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Deterministic selection for the questions a citizen asks about THEIR
        # OWN standing and about the campaign's own numbers: the points
        # balance, a requested earning action, the daily cap, the referral, the
        # price of a reward, the race leaderboard and where a donation goes.
        #
        # == Why these are deterministic
        #
        # None of them is hard to answer — the platform already owns every
        # number. They were unanswerable because the understanding call
        # classified them as +rewards+ (a CORE topic), and the rewards
        # catalogue answered first. Eleven balance phrasings verified against a
        # genuinely authenticated session all returned the same 1.422-character
        # eight-item catalogue while the citizen's real balance was 245 points.
        #
        # Selecting the topic here removes the model's opportunity to make that
        # substitution at all. Selection only: the Responder still resolves the
        # user, checks the conversation's trusted scope and reads nothing the
        # citizen may not read, and the catalogue reader still applies its own
        # authorization.
        #
        # == Where these sit in the order
        #
        # Last, after +launch_topic+. Every built-in keeps its position, which
        # is what keeps three distinctions the corpus proves matter:
        #
        #   * +earning+ still wins for "kako da zaradim bodove" and for
        #     "koliko bodova nosi prijava problema" — those are the schedule,
        #     not this citizen's ledger;
        #   * +invitation+ still wins for "imam li pozivnicu";
        #   * +launch_topic+ still pins "koliko bodova košta pozivnica" to the
        #     launch policy, where the answer is that the 20 points are a
        #     threshold and are never deducted.
        #
        # The pre-model PublicInformationStage runs BEFORE any of this, so the
        # reviewed race explanation and the vote-integrity invariant keep
        # precedence over the dynamic standings by construction.
        module PersonalReadRoutes
          # The same courtesy opener the own-state routes allow.
          PREFIX = /(?:(?:milica|milice|komsinice|komsinica|hej|ej|molim[ ]te|molim|a|pa|i|e)\s+)*/
          POINTS = /(?:bodov\w*|poen\w*|bod)/
          COLLECTED = /(?:skupio|skupila|sakupio|sakupila|osvojio|osvojila|zaradio|zaradila|stekao|stekla|dobio|dobila)/
          MINE = /(?:na\s+(?:svom|mom|mojem)\s+(?:nalogu|profilu|racunu)|na\s+nalogu|zajednistva|ukupno|do\s+sada|sada|sad|trenutno)/

          # The citizen's own balance, level or rank — never the schedule and
          # never the catalogue. Whole-utterance matches on folded text.
          BALANCE = /\A#{PREFIX.source}(?:
              koliko\s+(?:ja\s+)?imam\s+#{POINTS.source}(?:\s+#{MINE.source})*
             |koliko\s+#{POINTS.source}\s+(?:ja\s+)?imam(?:\s+#{MINE.source})*
             |koliko\s+(?:ja\s+)?sam\s+#{COLLECTED.source}\s+#{POINTS.source}(?:\s+#{MINE.source})*
             |koliko\s+sam\s+#{COLLECTED.source}\s+#{POINTS.source}(?:\s+#{MINE.source})*
             |koliko\s+#{POINTS.source}\s+sam\s+#{COLLECTED.source}(?:\s+#{MINE.source})*
             |(?:koje|kakvo|koliko)\s+je\s+(?:moje\s+)?stanje\s+(?:mojih\s+)?#{POINTS.source}
             |(?:moje\s+)?stanje\s+(?:mojih\s+)?#{POINTS.source}
             |moj[ie]\s+#{POINTS.source}
             |#{POINTS.source}\s+na\s+(?:mom|svom|mojem)\s+(?:nalogu|profilu|racunu)
             |(?:prikazi|pokazi|daj|vidi)(?:\s+mi)?\s+(?:moje\s+|moj\s+)?(?:#{POINTS.source}|stanje\s+#{POINTS.source})
             |(?:koji|koliki)\s+(?:je\s+moj|mi\s+je)\s+(?:rang|nivo|doprinos)(?:\s+u\s+zajednici)?
             |(?:koji|koliki)\s+sam\s+(?:nivo|rang)
             |(?:na\s+)?(?:kom|kojem)\s+sam\s+(?:nivou|rangu)
             |moj\s+(?:rang|nivo|doprinos)(?:\s+u\s+zajednici)?
             |imam\s+li\s+#{POINTS.source}
             |how\s+many\s+points\s+do\s+i\s+have
             |my\s+points(?:\s+balance)?
          )\z/x

          # "Why hasn't my referral paid?" / "when do the points arrive?" —
          # the value itself is already served by the +earning+ route, which
          # answers the REQUESTED action rather than a top-five ranking.
          REFERRAL_SUBJECT = /(?:poziv(?:a|u|om|nom)?\b|pozovem|pozvao|pozvala|pozvan\w*|preporuk\w*|referral|link\w*)/
          REFERRAL_CONTEXT = /(?:komsij|komsiluk|prijatelj|susjed|susjeda|drugar|brata|sestru|nekoga|nekog)/
          REFERRAL_PENDING = /(?:zasto\s+(?:jos\s+)?(?:nema|nisam|nije)|kad(?:a)?\s+(?:stizu|stize|dobijam|dobijem|ce\s+stici)|jos\s+nema|nisu\s+stigli|nije\s+stiglo)/

          # The documented product rule nothing has ever said out loud: an
          # action over its daily cap still executes and simply earns nothing.
          CAP_SUBJECT = /(?:dnevn\w*\s+(?:granic\w*|limit\w*|ogranicenj\w*|maksimum\w*|kvot\w*)
                          |granic\w*\s+(?:po\s+danu|dnevno)|limit\w*\s+(?:po\s+danu|dnevno)
                          |(?:sest\w*|peta|petu|sedm\w*|jedanaest\w*)\s+prijav\w*
                          |vise\s+od\s+\d+\s+(?:prijav\w*|komentar\w*|prijedlog\w*|predlog\w*)
                          |preko\s+dnevn\w*)/x
          CAP_CLAIM = /(?:bodov|poen|odbij|nece\s+(?:proci|biti)|blokir|ne\s+racuna|ne\s+vazi|ne\s+prolazi|ne\s+prihvat|zabran)/

          # The price of a named reward, or the cheapest ones. The catalogue
          # reader answers it; this only stops the model from sending a price
          # question to the donation totals or the partner directory.
          REWARD_SUBJECT = /(?:nagrad\w*|majic\w*|torb\w*|termos\w*|naljepnic\w*|nalepnic\w*|zahvalnic\w*|kupon\w*|radionic\w*|priznanj\w*)/
          REWARD_PRICE_CUE = /(?:kost|cijen|cjenovnik|koliko\s+#{POINTS.source}|najjeftin|najpovoljn|najskup
                               |koliko\s+treba|koliko\s+mi\s+treba|mogu\s+li\s+uzeti|mogu\s+li\s+dobiti)/x

          # AFFORDABILITY is not the price and it is not the balance: it is
          # the COMPARISON of the two, and neither half answers it. Asked
          # signed in on 14.09, "Da li imam dovoljno bodova za majicu?"
          # returned the three cheapest rewards with their prices and the
          # majica not among them — the citizen's own balance was 360 and the
          # reply never mentioned it. Asked one turn after a balance question,
          # it returned the balance reply byte for byte and never mentioned a
          # price. Both numbers exist; nothing put them in one sentence.
          #
          # Deliberately narrow. A sufficiency word plus a reward subject
          # plus a points word, or one of the two words that mean purchasing
          # power on their own. "Mogu li uzeti majicu?" is NOT here: it is a
          # price question and +reward_price+ already owns it.
          AFFORD_CUE = /(?:\bdovoljno\b|\bdosta\b|\bfali\b|\bnedostaje\b|\bmanjka\b|\benough\b)/
          AFFORD_STRONG = /(?:priusti\w*|\bafford\w*)/

          # "Who is leading?" — the cached standings, never the Scorer and
          # never a server-side HTTP call to the projector screen's JSON.
          #
          # Two shapes, deliberately. A BARE "ko vodi?" is a follow-up and is
          # matched whole-utterance only, because "ko vodi ovu platformu" and
          # "ko vodi Fondaciju" are questions about who RUNS something and were
          # asked in the rated corpus. Anything longer has to name the race.
          LEADS = /(?:vodi|predvodi|je\s+prvi|je\s+prva|je\s+na\s+prvom\s+mjestu|je\s+na\s+prvom\s+mestu|je\s+na\s+vrhu)/
          LEADING_BARE = /\A#{PREFIX.source}(?:
              (?:ko|koji\s+komsiluk|koje\s+naselje)\s+(?:trenutno\s+|sad\s+|sada\s+)?#{LEADS.source}
             |who\s+is\s+(?:currently\s+)?(?:leading|winning|first)
          )\z/x
          LEADING_NAMED = /(?:(?:ko|koji\s+komsiluk|koje\s+naselje)\s+(?:trenutno\s+|sad\s+|sada\s+)?#{LEADS.source}
                            |(?:trenutn\w*\s+)?(?:poredak|poretku|poretka|tabel\w*|rezultat\w*|standing\w*)
                            |(?:gdje|gde)\s+(?:mogu\s+)?(?:da\s+)?(?:vidim|pogledam|pratim)\s+(?:trenutn\w*\s+)?(?:poredak|tabel\w*|rezultat\w*))/x
          # The race by name, or the two leagues it is played in.
          RACE_NAMED = /(?:\btrk[aeiou]\b|\btrci\b|komsiluk|susjedstv|\bsel[oau]\b\s+(?:protiv|i)\s+grad|liga|lige)/
          RACE_EXCLUSION = /(?:izbor|referendum|utakmic|premijer|platform|fondacij|udruzenj|opstin|gradsk\w*\s+uprav)/

          # Where the money goes, as opposed to how much of it there is. The
          # bank details live on the foundation's own published record and are
          # reached only by a GIVING question — never by a race or points one.
          GIVING = /(?:kako\s+(?:da\s+|mogu\s+(?:da\s+)?)?(?:doniram|donirati|uplatim|uplatiti|pomognem|pomoci|priloz\w*)
                     |(?:gdje|gde)\s+(?:mogu\s+)?(?:da\s+)?(?:uplatim|uplatiti|doniram|donirati|posaljem\s+novac)
                     |(?:mislio|mislila)\s+sam\s+donir\w*|broj\s+racuna|racun\s+za\s+(?:uplat\w*|donacij\w*)|zelim\s+(?:da\s+)?donir
                     |link\s+za\s+(?:donacij\w*|uplat\w*)|how\s+(?:can|do)\s+i\s+donate)/x
          # "Neću sada plaćati", "ne želim donirati": a refusal is not a giving
          # question, and answering it with an account number is worse than
          # answering nothing.
          # Widening this can only make a giving question harder to recognise,
          # which is the safe direction: a missed one falls through to the rest
          # of the turn, a false one prints an account number.
          GIVING_REFUSED = /\b(?:ne|necu|neces|nece|nemoj(?:te)?|nisam|necemo|bez)\s+(?:\w+\s+){0,3}?(?:donir|uplat|plac|plati|racun)/
          ALLOCATION = /(?:kome\s+(?:je\s+)?(?:dodijel|dodel|ide|idu|odlaz)
                         |(?:kako|na\s+sta|na\s+shta)\s+se\s+(?:trose|potrose|koriste)\s+(?:donacij\w*|novac|sredstv\w*)
                         |(?:koje|koji)\s+projekt\w*\s+(?:mogu\s+)?(?:podrz|podrs|biram|izabrati|odabrati)
                         |mogu\s+li\s+(?:prvo\s+)?(?:vidjeti|videti|birati|izabrati)\s+(?:projekt\w*|kome)
                         |spisak\s+projek\w*|ko\s+odlucuje\s+o\s+projekt\w*)/x
          DONATION_CONTEXT = /(?:donacij|donir|uplat|prilog|projekt|sredstv|novac|novca)/

          # The longest utterance any of these will read. CivicQuestion bounds
          # the whole message at 160; a trailing clause is bounded tighter
          # because a long tail is prose, not a question.
          MAX_CLAUSE = 120

          module_function

          # A corrective turn ("Ne pitam za nagrade. Koliko bodova imam na svom
          # nalogu?") asks its real question in the LAST clause. Splitting on
          # sentence punctuation is the same shape Coordinator#cancellation_question
          # already uses, and the clause is folded exactly like the whole
          # utterance, so no matcher below has to know about it.
          def clause(text)
            parts = text.to_s.split(/[.!?;,\n]+/).map(&:strip).reject(&:empty?)
            return if parts.length < 2

            last = parts.last
            return unless last.length <= MAX_CLAUSE

            Decidim::Bih::Text.fold(last)
          end

          # True when EVERY pattern matches the whole folded utterance, or when
          # every one of them matches its last clause. Never a mix of the two:
          # a subject from the opening sentence and a claim from the closing one
          # are not the same question.
          def matches?(query, text, *patterns)
            return true if patterns.all? { |pattern| pattern.match?(query) }

            tail = clause(text)
            !tail.nil? && patterns.all? { |pattern| pattern.match?(tail) }
          end

          def balance?(query, text) = matches?(query, text, BALANCE)

          def referral_pending?(query, text)
            matches?(query, text, REFERRAL_PENDING, REFERRAL_SUBJECT, POINTS)
          end

          # The Responder answers a referral question with the RULES — value,
          # delay, gate and monthly limit — even when the deterministic route
          # sent the turn down the shared "earning" path, because the value
          # alone is the half of the answer that was never the problem.
          def referral?(query, text)
            return true if referral_pending?(query, text)

            matches?(query, text, REFERRAL_SUBJECT, REFERRAL_CONTEXT, POINTS)
          end

          def cap?(query, text) = matches?(query, text, CAP_SUBJECT, CAP_CLAIM)

          def reward_price?(query, text) = matches?(query, text, REWARD_SUBJECT, REWARD_PRICE_CUE)

          # See AFFORD_CUE. Checked BEFORE the balance and before the price,
          # because both of those answer half of it and sound complete.
          def affordability?(query, text)
            return true if matches?(query, text, AFFORD_STRONG, REWARD_SUBJECT)

            matches?(query, text, AFFORD_CUE, REWARD_SUBJECT, POINTS)
          end

          def race_standings?(query, text)
            return false if RACE_EXCLUSION.match?(query)
            return true if matches?(query, text, LEADING_BARE)

            RACE_NAMED.match?(query) && matches?(query, text, LEADING_NAMED)
          end

          def giving?(query, text)
            return false if GIVING_REFUSED.match?(query)

            matches?(query, text, GIVING)
          end

          def allocation?(query, text) = matches?(query, text, ALLOCATION, DONATION_CONTEXT)
        end

        # AFFORDABILITY — the balance AND the price, in one sentence. First,
        # because the balance route below answers half of it and the reward
        # price route answers the other half, and each of those halves reads
        # like a complete answer to a citizen who asked for the comparison.
        DeterministicRoutes.register("reward_affordability") do |query, text|
          { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "affordability" } } if PersonalReadRoutes.affordability?(query, text)
        end

        # BALANCE — the citizen's own ledger row. `goodwill` is not a CORE
        # topic, so this reaches the secondary read adapter and the Responder's
        # existing classifier-free, read-only goodwill handler.
        DeterministicRoutes.register("goodwill_balance") do |query, text|
          { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "balance" } } if PersonalReadRoutes.balance?(query, text)
        end

        # REFERRAL — value, delay, eligibility and the monthly limit. Separate
        # from the balance because the honest answer to "why hasn't it paid" is
        # a rule, not a number from this citizen's account.
        DeterministicRoutes.register("goodwill_referral") do |query, text|
          if PersonalReadRoutes.referral?(query, text)
            category = PersonalReadRoutes.referral_pending?(query, text) ? "referral_pending" : "referral"
            { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => category } }
          end
        end

        # DAILY CAP — the cap never blocks the civic action, only the award.
        DeterministicRoutes.register("goodwill_daily_cap") do |query, text|
          { action: "ask_information", topic: "goodwill", entities: { "query" => text, "category" => "cap" } } if PersonalReadRoutes.cap?(query, text)
        end

        # RACE STANDINGS — the cached leaderboard, grad and selo apart. The
        # reviewed race explanation is answered earlier, by the pre-model
        # public-information card; this is the live half of the same subject
        # and only ever sees the phrasings that card declines.
        #
        # Registered BEFORE +launch_topic+: that route pins "trka komšiluka" to
        # the launch policy, which is right for a rules question and wrong for
        # "gdje vidim trenutni poredak Trke komšiluka".
        DeterministicRoutes.register("race_standings", before: "launch_topic") do |query, text|
          { action: "ask_information", topic: "launch", entities: { "query" => text, "category" => "race_standings" } } if PersonalReadRoutes.race_standings?(query, text)
        end

        # REWARD PRICE — the catalogue reader answers it, with the cost.
        DeterministicRoutes.register("reward_price") do |query, text|
          { action: "ask_information", topic: "rewards", entities: { "query" => text } } if PersonalReadRoutes.reward_price?(query, text)
        end

        # DONATION — a giving question reaches the foundation's own published
        # record (which is where the payment instructions live); an allocation
        # question reaches the approved project list. Neither is the aggregate
        # total, and neither is reachable from a race or points question.
        DeterministicRoutes.register("donation_giving") do |query, text|
          { action: "ask_information", topic: "community", entities: { "query" => text, "category" => "organizacija" } } if PersonalReadRoutes.giving?(query, text)
        end

        DeterministicRoutes.register("donation_allocation") do |query, text|
          { action: "ask_information", topic: "community", entities: { "query" => text, "category" => "projekti" } } if PersonalReadRoutes.allocation?(query, text)
        end
      end
    end
  end
end

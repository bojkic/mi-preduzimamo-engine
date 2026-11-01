# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # WHICH account journey the citizen is asking about, from their own
        # current words.
        #
        # == Why this exists
        #
        # Opening an account, signing in to an existing one, confirming a phone
        # number, confirming an address by post, recovering a message that
        # never arrived, the required fields, the newsletter option, signing
        # out and asking for deletion are NINE different things. The rated
        # corpus shows all of them collapsing into one clarifying menu
        # ("Treba li ti otvaranje naloga, prijava, potvrda naloga ili
        # objašnjenje uslova registracije?") — 15 of 37 turns, twice in a row
        # in six conversations, including immediately after the citizen said
        # "Ništa od toga". The menu option typed BARE resolved; the same option
        # plus a clarifying sentence looped.
        #
        # The cause is that the account procedure classified from the model's
        # rewritten +query+ and knew only three subjects. This module is the
        # missing classifier: pure text in, one facet name out, no model call,
        # no read, no state.
        #
        # == The contract
        #
        # +facet+ returns one of +FACETS+ or nil. It never guesses: an
        # utterance it does not recognise returns nil and the caller falls back
        # to the menu (once) and then to a working route. Selection only — the
        # answer, the account state and the destination stay with the caller,
        # which is the only place that may read the registration port.
        #
        # Three of the facets are ROUTES rather than explanations
        # (+register+, +sign_in+, +verify+). They exist so that every menu
        # choice works as natural text and as a tapped chip, which is what the
        # corpus proves is not true today.
        module AccountQuestion
          # Account questions are short. Anything longer is prose, a report or
          # a paste, and a canned account card is the wrong answer for it.
          MAX_LENGTH = 240

          ROUTES = { "register" => "registration", "sign_in" => "sign_in", "verify" => "verification" }.freeze
          # Facets answered from the citizen's own account rather than from the
          # registration form: they point at the signed-in account surface.
          ACCOUNT_SURFACE = %w(settings sign_out deletion phone_visibility already_registered).freeze

          # --- routes (the menu choices, as natural text) ----------------------
          REGISTER_ROUTE = /\A(?:(?:zelim|hocu|hoces|mogu[ ]li|da[ ])?\s*)?(?:otvaranje\s+(?:naloga|racuna)|otvori(?:ti|mo)?\s+(?:nalog|racun)
                             |napravi(?:ti|mo)?\s+(?:nalog|racun)|registracija|registruj\s+me|nova\s+registracija|create\s+an?\s+account|sign\s+up)\s*\z/x
          # The sign-in route also owns the two ways a citizen says it without
          # the word "nalog": a forgotten password, and signing in with the
          # phone INSTEAD of one. Both are rated positive controls; neither may
          # become an explanation of why we ask for a phone number.
          SIGN_IN_ROUTE = /(?:prijava\s+na\s+(?:postojeci\s+)?(?:nalog|racun)|prijavi(?:ti)?\s+se\s+na\s+(?:postojeci\s+)?(?:nalog|racun)
                            |ulaz\s+u\s+(?:nalog|racun)|sign\s+in\s+to\s+an?\s+existing\s+account
                            |zaboravi\w*\s+(?:sam\s+)?lozink\w*|forgot\s+(?:my\s+)?password
                            |(?:umjesto|umesto)\s+lozink\w*|prijavi(?:ti)?\s+se\s+telefonom|prijava\s+telefonom)/x
          VERIFY_ROUTE = /\A(?:potvrda\s+(?:broja|broja\s+telefona|telefona|naloga|racuna)|verifikacija(?:\s+(?:broja|telefona|naloga))?
                           |provjera\s+broja(?:\s+telefona)?|potvrdi(?:ti)?\s+(?:broj|telefon|nalog)|verify\s+(?:my\s+)?(?:phone|account|number))\s*\z/x

          # --- already registered ---------------------------------------------
          #
          # b4c03: a SIGNED-IN citizen asked "Već sam prijavljen, da li moram
          # ponovo?" and got the menu. Whatever else is true, the answer must
          # never be "register".
          ALREADY = /(?:vec\s+(?:sam|imam)|imam\s+(?:vec\s+)?(?:nalog|racun|profil)|already\s+(?:have|registered|signed))/
          AGAIN = /(?:ponovo|opet|jos\s+jednom|dva\s+puta|again|twice|moram\s+li|da\s+li\s+moram|need\s+to)/

          # --- sign out --------------------------------------------------------
          SIGN_OUT = /(?:odjav\w*|odloguj\w*|izloguj\w*|log\s*out|sign\s*out|signed\s*out)/

          # --- deletion --------------------------------------------------------
          DELETE_ACTION = /(?:\bobris\w*|\bizbris\w*|\bbris\w*|ugasi\w*|ukini\w*|zatvor\w*|delete|remove|close)/
          ACCOUNT_OBJECT = /(?:nalog\w*|racun\w*|profil\w*|account|podatke|podataka|podaci)/

          # --- settings --------------------------------------------------------
          SETTINGS = /(?:postavk\w*|podesavanj\w*|podesenj\w*|settings|preferences)/

          # --- phone visibility -------------------------------------------------
          VISIBILITY = /(?:vid[ei]\b|vidi\w*|vide\w*|vidljiv\w*|javn\w*|objavljuj\w*|objav\w*|ko\s+moze|drugi\s+gradjani|ostali|see|public|visible)/
          # Observing the current sender is a trusted-context question, not the
          # public exposure policy. A provider name in prose proves neither.
          DIRECT_OBSERVATION = /\b(?:vidis\s+(?:li\s+)?(?:ti\s+)?|vidite\s+(?:li\s+)?|(?:mozes|mozete)\s+(?:li\s+)?(?:ti\s+)?(?:vidjeti|videti)|(?:can|do)\s+you\s+see)\b/
          PHONE_WORD = /(?:telefon\w*|mobitel\w*|mobiln\w*|phone|telephone|mobile)/
          # "broj" alone is a number of many things (a reservation, a report),
          # so it only counts as the phone inside an account/registration
          # sentence.
          NUMBER_IN_ACCOUNT = /\bbroj\w*\b.{0,60}(?:registracij\w*|nalog\w*|racun\w*|prijav[ai]\b|potvrd\w*)|(?:registracij\w*|nalog\w*|racun\w*|potvrd\w*).{0,60}\bbroj\w*\b/

          # --- phone purpose ----------------------------------------------------
          PURPOSE_CUE = /\b(?:zasto|cemu|treba\w*|obavezn\w*|moram|bez|why|need\w*|required|necessary|mandatory|without)\b/
          # A question about CHANGING or REMOVING the number is account
          # management, not the registration purpose card.
          PHONE_MUTATION = /\b(?:promijen|promjen|promen|mijenj|menj|izmijen|izmjen|izmen|zamijen|zamjen|zamen|obris|izbris|bris)\w*\b
                            |\b(?:chang|updat|replac|switch|reset|delet|remov|unlink)\w*\b/x

          # --- verification lifetime --------------------------------------------
          LIFETIME_CUE = /(?:koliko\s+(?:traje|vazi|sati|vremena|dugo)|dokad\w*|do\s+kada|istek\w*|istic\w*|\brok\b|\broka\b|\broku\b
                           |vazi\s+li|koliko\s+je\s+vazec|how\s+long|expire\w*|valid\s+for)/x
          TOKEN_WORD = /(?:link\w*|vez[auei]\b|vezu\b|poveznic\w*|\bkod\b|\bkoda\b|\bkodu\b|kod\s+iz|sms\b|poruk\w*|potvrd\w*|verifikacij\w*|token)/

          # --- typing the code instead of tapping the link -----------------------
          NO_SMARTPHONE = /(?:nemam\s+pametni\s+telefon|bez\s+pametnog\s+telefon\w*|obicni\s+telefon|stari\s+telefon|dugmic\w*
                            |nemam\s+internet\s+na\s+telefonu|no\s+smartphone|old\s+phone)/x
          CODE_ENTRY = /(?:(?:unos|unes|upis|prepis|ukuc|otkuc)\w*\s+(?:taj\s+|onaj\s+|moj\s+)?kod|kod\s+(?:iz|sa)\s+(?:sms|poruk)
                         |sms\s*kod|kodom\s+umjesto|kod\s+umjesto\s+link|umjesto\s+link\w*|umesto\s+link\w*|rucno\s+prepis\w*|\brucno\b
                         |gdje\s+(?:se\s+)?(?:unosi|unesem|upisuje|upisem)|gde\s+(?:se\s+)?(?:unosi|unesem|upisuje|upisem)
                         |ne\s+trazim\s+slanje|ne\s+salji\w*\s+(?:kod|nista)
                         |enter\s+the\s+code|type\s+the\s+code)/x

          # --- the message that never arrived -------------------------------------
          MISSING_MESSAGE = /(?:ne\s+stiz\w*(?:\s+mi)?|nis[ai]m\s+dobi\w*|nije\s+(?:stigl\w*|stigao|dosl\w*|dosao)|ne\s+dobijam|ne\s+dolazi|nema\s+poruke|nije\s+mi\s+stigl\w*
                              |ponovn?o\s+slanje|ponovi\w*\s+slanje|posalji\s+ponovo|novi\s+kod|nov[au]\s+poruk\w*|resend|did\s+not\s+(?:get|receive))/x
          CHANNEL_WORD = /(?:viber|whatsapp|wapp|sms|poruk\w*|kod\w*)/

          # --- e-mail --------------------------------------------------------------
          EMAIL_WORD = /(?:e\s*mail\w*|email\w*|mejl\w*|elektronsk\w*\s+post\w*|\bmail\b)/
          EMAIL_CUE = /\b(?:bez|nemam|obavezn\w*|moram|treba\w*|mogu\s+li|da\s+li|required|without|optional|need\w*)\b/

          # --- postal / address confirmation ----------------------------------------
          POSTAL = /(?:postansk\w*|pismo\w*|pismom|postom|\bposta\b|adres\w*)/
          POSTAL_CUE = /(?:potvrd\w*|verifikacij\w*|razlik\w*|provjer\w*|isto\s+sto|\bpismo\b)/

          # --- residency ---------------------------------------------------------------
          RESIDENCY = /(?:zivim\s+(?:van|izvan|u\s+drugom)|ne\s+zivim\s+u|van\s+bijeljin\w*|izvan\s+bijeljin\w*|nisam\s+iz\s+bijeljin\w*
                        |iz\s+drugog\s+(?:grada|mjesta)|nemam\s+prebivalist\w*|prebivalist\w*|live\s+outside)/x

          # --- what the form asks for ---------------------------------------------------
          FIELDS_CUE = /(?:podat\w*|podac\w*|dokument\w*|spisak|list[au]\b|polj[aei]\b|rubrik\w*|sta\s+(?:mi\s+)?treba|sta\s+je\s+potrebno
                         |koji\s+su\s+uslovi|what\s+do\s+i\s+need|which\s+fields)/x

          # --- what registration is worth -------------------------------------------------
          AWARD_CUE = /(?:bodov\w*|poen\w*|nagrad\w*|dobij\w*\s+li\s+(?:nesto|sta)|dobijam\s+li\s+(?:nesto|sta)
                        |sta\s+dobij\w*|ima\s+li\s+(?:kakve\s+)?koristi|what\s+do\s+i\s+get)/x

          # --- terms and newsletter (the two the runner already knew) -----------------------
          #
          # Both were matched on one word each, and the corpus asks for them in
          # other ones. "Koja saglasnost je obavezna pri registraciji?" is the
          # terms question with the legal noun instead of "uslovi", and
          # "Moram li prihvatiti promotivne poruke da koristim MI?" is the
          # newsletter question with the marketing noun instead of "novosti" —
          # the same question phrased "Ne želim novosti" was already answered
          # correctly, which is what proves these are vocabulary gaps and not
          # missing answers.
          TERMS = /\b(?:uslov\w*|uvjet\w*|saglasnos\w*|pristanak|pristanka|privol\w*|terms|consent)\b/
          # The marketing wording needs its NOUN: "promotivne poruke" is the
          # newsletter, "promotivne cijene za parking" is not.
          NEWSLETTER = /\b(?:newsletter\w*|novost\w*|bilten\w*)\b
                        |\b(?:promotivn|promocijsk|reklamn|marketins?k)\w*[ ]
                         (?:poruk\w*|mejl\w*|e[ ]mail\w*|mail\w*|obavjestenj\w*|obavestenj\w*|sadrzaj\w*|ponud\w*)
                        |\b(?:email|e[ ]mail)[ ](?:updates|news|marketing)\b/x

          FACETS = (ROUTES.keys + %w(
            already_registered sign_out deletion settings phone_visibility phone_purpose
            verification_lifetime code_entry message_missing email_requirement postal_difference
            residency registration_award required_fields terms newsletter
          )).freeze

          module_function

          # The facet this utterance asks about, or nil. +text+ is the
          # citizen's own message; the caller may retry with the model's
          # bounded query when the citizen's words alone are not enough.
          def facet(text)
            return unless text.is_a?(String)

            stripped = text.strip
            return unless stripped.length.between?(1, MAX_LENGTH)

            query = Decidim::Bih::Text.fold(stripped)
            return if query.empty?

            # A correction names the account need in its positive final clause.
            query = query.sub(/\A(?:nije\s+korisno\s+)?vec\s+imam\s+nalog\s+treba\s+mi\s+/, "")
            facet_for(query)
          end

          # THE RULE SET IS THE ORDER. Each entry is [facet, matcher] and the
          # first matcher that recognises the utterance wins, so reading the
          # two lists top to bottom is reading the policy:
          #
          #   * the menu ROUTES first, so a tapped chip and its own words do
          #     the same thing before any explanation can claim them;
          #   * "already registered" before everything else, because a
          #     signed-in citizen must never be answered with "register";
          #   * a citizen with no smartphone is asking about the CODE, whatever
          #     else their sentence says about phones;
          #   * account management (sign out, deletion, settings, the number's
          #     visibility) before the registration explanations, because they
          #     are about an account that already exists;
          #   * the phone PURPOSE after its visibility, so "why do you want my
          #     number" and "who can see my number" stay two questions.
          ACCOUNT_RULES = [
            ["already_registered", ->(query) { ALREADY.match?(query) && AGAIN.match?(query) }],
            ["code_entry", ->(query) { NO_SMARTPHONE.match?(query) }],
            ["sign_out", ->(query) { SIGN_OUT.match?(query) }],
            ["deletion", ->(query) { DELETE_ACTION.match?(query) && ACCOUNT_OBJECT.match?(query) }],
            ["newsletter", ->(query) { NEWSLETTER.match?(query) }],
            ["settings", ->(query) { SETTINGS.match?(query) }],
            ["phone_visibility", ->(query) { phone_subject?(query) && VISIBILITY.match?(query) && !direct_phone_observation?(query) }],
            ["phone_purpose", ->(query) { phone_purpose?(query) }]
          ].freeze

          # Everything the REGISTRATION FORM and its message chain explain.
          REGISTRATION_RULES = [
            ["verification_lifetime", ->(query) { LIFETIME_CUE.match?(query) && TOKEN_WORD.match?(query) }],
            ["message_missing", lambda { |query|
              MISSING_MESSAGE.match?(query) || (CHANNEL_WORD.match?(query) && /nemam|postoji|opcij\w*|samo\s+sms/.match?(query))
            }],
            ["code_entry", ->(query) { CODE_ENTRY.match?(query) }],
            ["email_requirement", ->(query) { EMAIL_WORD.match?(query) && EMAIL_CUE.match?(query) }],
            ["postal_difference", ->(query) { POSTAL.match?(query) && POSTAL_CUE.match?(query) }],
            ["residency", ->(query) { RESIDENCY.match?(query) }],
            ["terms", ->(query) { TERMS.match?(query) }],
            ["registration_award", ->(query) { AWARD_CUE.match?(query) }],
            ["required_fields", ->(query) { FIELDS_CUE.match?(query) }]
          ].freeze

          # A bare "the message still does not arrive" is account recovery
          # only after an actual missing-code question. It never borrows an
          # account subject from a report draft or from a general chat message.
          def missing_message_follow_up?(text, state)
            return false unless state["active_task"] == "ask_information" && state["topic"] == "account"
            return false if state["draft"] || state["pending_slot"] == "description"
            return false unless facet(state.fetch("entities", {})["query"]) == "message_missing"
            return false unless text.is_a?(String) && text.length <= MAX_LENGTH

            query = Decidim::Bih::Text.fold(text)
            /\A(?:(?:sta\s+da\s+uradim\s+ako|sta\s+ako|a|ali)\s+)?(?:poruka|kod)(?:\s+(?:mi|i\s+dalje|nikako|jos))*(?:\s+ne\s+(?:dolazi|stize)|\s+nije\s+(?:stigla|stigao|dosla|dosao))\z/.match?(query)
          end

          def facet_for(query)
            route_for(query) || matched(ACCOUNT_RULES, query) || registration_facet(query)
          end

          def registration_facet(query)
            # Changing or removing a number that is already on the account is
            # NOT the registration form. We have no reviewed instructions for
            # it, so nothing below may answer as if we did.
            return if phone_subject?(query) && PHONE_MUTATION.match?(query)

            matched(REGISTRATION_RULES, query)
          end

          def matched(rules, query)
            rules.find { |(_, rule)| rule.call(query) }&.first
          end

          def route_for(query)
            return "register" if REGISTER_ROUTE.match?(query)
            return "sign_in" if SIGN_IN_ROUTE.match?(query)
            return "verify" if VERIFY_ROUTE.match?(query)

            nil
          end

          def direct_phone_observation?(query)
            phone_subject?(query) && DIRECT_OBSERVATION.match?(query)
          end

          def phone_subject?(query)
            PHONE_WORD.match?(query) || NUMBER_IN_ACCOUNT.match?(query)
          end

          # Unchanged from the runner's original predicate, except that a bare
          # "broj" inside an account sentence now counts as the phone: b3c11
          # asked "Zašto tražite broj pri registraciji?" and was given the menu
          # because the word "telefon" was missing.
          def phone_purpose?(query)
            return false unless phone_subject?(query)
            return false if PHONE_MUTATION.match?(query)

            PURPOSE_CUE.match?(query)
          end

          # The locale key for an explanation facet. Routes have none.
          def information_key(name)
            case name
            when "terms" then "registration_terms_information"
            when "newsletter" then "registration_newsletter_information"
            when "phone_purpose" then "registration_phone_information"
            else ROUTES.has_key?(name) ? nil : "account_#{name}"
            end
          end

          # "Da li drugi građani vide broj telefona s mog naloga?" — the one
          # account question a generic privacy card would otherwise swallow.
          def phone_visibility_question?(text)
            return false unless text.is_a?(String) && text.strip.length.between?(1, MAX_LENGTH)

            query = Decidim::Bih::Text.fold(text)
            facet_for(query) == "phone_visibility"
          end
        end
      end
    end
  end
end

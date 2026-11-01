# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        module Characterisation
          # The named prompt set the Task 0 extraction is characterised over.
          # It spans the five families the plan requires — emergency, civic,
          # service, registration and catalogue answers — plus the control,
          # follow-up and report paths that share the same seams.
          #
          # Cases are conversations: every step of a case runs against the state
          # the previous step saved, so continuity paths (evidence follow-ups,
          # clarification chains, service follow-ups) are covered too.
          # The corpus is fixture data: one conversation per entry with its
          # canned read result on the same line. Reflowing those entries to the
          # line limit hides the case boundaries that make the transcript
          # reviewable, so the layout cops are off for this file only.
          # rubocop:disable Layout/LineLength, Style/HashSyntax, Layout/FirstArrayElementIndentation, Metrics/ParameterLists
          module Corpus
            module_function

            def understanding(action:, topic:, operation: "start", entities: {}, locale: "sr", clarification: false, secondary: nil)
              lambda do
                Contracts::Understanding.parse(action:, topic:, entities:, operation:, locale:,
                                               needs_clarification: clarification, secondary:)
              end
            end

            def fact(id:, text:, **extra)
              { "id" => id, "kind" => "city_service_notice", "text" => text,
                "source_id" => "grad_bijeljina", "source_label" => "Grad Bijeljina",
                "source_url" => "https://bijeljina.example/obavjestenja" }.merge(extra.transform_keys(&:to_s))
            end

            def water_fact(id:, text:, observed_at:)
              { "id" => id, "kind" => "water_level_observation", "text" => text, "observed_at" => observed_at,
                "source_id" => "rhmz", "source_label" => "RHMZ", "source_url" => "https://rhmz.example/vodostaji" }
            end

            # The retained-evidence follow-ups only fire for an identifier the
            # host owns: a registry stop, a service directory card, a procedure.
            def transport_stop_fact
              { "id" => "transport_stop:abc123def456", "kind" => "transport_stop", "text" => "Polazna stanica: Dvorovi (centar).",
                "source_id" => "public_transport_stop_registry", "source_label" => "Registar stajališta" }
            end

            def directory_fact
              { "id" => "service:vodovod", "kind" => "city_service_directory", "text" => "Vodovod Bijeljina održava mrežu u Dvorovima.",
                "source_id" => "city_services:vodovod", "source_label" => "Vodovod Bijeljina" }
            end

            def procedure_fact
              { "id" => "procedure:uvjerenje", "kind" => "city_service_procedure", "text" => "Uvjerenje o prebivalištu izdaje MUP, šalter 2.",
                "source_id" => "procedure:uvjerenje", "source_label" => "Grad Bijeljina" }
            end

            def service_event_fact(id:, body:, qualifiers:, **extra)
              { "id" => id, "kind" => "city_service_event", "answer_shape" => "service_event_v1",
                "text" => ([body] + qualifiers.values).join(" "), "notice_body" => body, "notice_qualifiers" => qualifiers,
                "source_id" => "vodovod", "source_label" => "Vodovod Bijeljina",
                "source_url" => "https://vodovod.example/radovi" }.merge(extra.transform_keys(&:to_s))
            end

            def cases
              emergency + civic + service + registration + catalogue + control + continuity + reports
            end

            def emergency
              [
                { name: "emergency_threat", steps: [{ text: "Neko mi prijeti, bojim se" }] },
                { name: "emergency_ambulance", steps: [{ text: "Treba mi hitna pomoć odmah" }] },
                { name: "emergency_domestic_violence_en", steps: [{ text: "This is domestic violence, what do I do" }] },
                { name: "emergency_signalled_message", steps: [{ text: "Bojim se za svoju sigurnost", safety_signal: true }] },
                { name: "emergency_cyrillic_police", steps: [{ text: "Зови полицију, напали су ме" }] },
                { name: "emergency_after_cancel", steps: [{ text: "Odustani. Neko mi prijeti." }] },
                { name: "emergency_follow_up_after_answer",
                  steps: [{ text: "Neko mi prijeti" }, { text: "A šta ako se vrati sutra?", understanding: understanding(action: "help", topic: "unknown", operation: "clarify", clarification: true) }] },
                { name: "allegation_corruption", steps: [{ text: "Prijavljujem korupciju u opštini" }] },
                { name: "precedence_credentials_refused", steps: [{ text: "Moj kod je 123456" }] },
                { name: "precedence_personal_number_mentioned", steps: [{ text: "Moj JMBG je 0101990123456" }] }
              ]
            end

            def civic
              [
                { name: "civic_document_birth_certificate", steps: [{ text: "Kako da izvadim rodni list", read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 13, 8), facts: [fact(id: "proc:rodni-list", text: "Rodni list se vadi u matičnoj službi, šalter 3.", "reviewed_on" => "2026-09-01")]) }] },
                { name: "civic_board_notices", steps: [{ text: "Ima li obavjestenja na tabli mog komsiluka", read: Contracts::ReadResult.new(status: "not_authorized") }] },
                { name: "civic_earn_points", steps: [{ text: "Kako da zaradim bodove", read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 13, 8), facts: [fact(id: "goodwill:schedule", text: "Registracija nosi 20 bodova.", "source_id" => "bodovnik", "source_label" => "Bodovnik")]) }] },
                { name: "civic_earn_points_phrase", steps: [{ text: "kako se skupljaju bodovi", read: Contracts::ReadResult.new(status: "empty") }] },
                { name: "civic_earn_value", steps: [{ text: "Koliko bodova nosi prijava problema", read: Contracts::ReadResult.new(status: "empty") }] },
                { name: "civic_pharmacy_tonight", steps: [{ text: "Ima li dežurna apoteka noćas?", read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), facts: [fact(id: "health:apoteka", text: "Dežurna apoteka: Zdravlje, Karađorđeva 5, 0-24.", "source_id" => "dom_zdravlja", "source_label" => "Dom zdravlja Bijeljina")]) }] },
                { name: "civic_invitation_status", steps: [{ text: "Jesam li pozvan na 17.9?", read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 7), facts: [fact(id: "launch:invitation", text: "Imaš rezervaciju broj 128.", "source_id" => "launch", "source_label" => "Lansiranje")]) }] },
                { name: "civic_invitation_reservation_number", steps: [{ text: "moj broj rezervacije", read: Contracts::ReadResult.new(status: "empty") }] },
                { name: "civic_launch_date", steps: [{ text: "kada je lansiranje platforme", read: Contracts::ReadResult.new(status: "empty") }] },
                { name: "civic_komsiluk_mine", steps: [{ text: "Koji je moj komšiluk?", read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 7), facts: [fact(id: "own:komsiluk", text: "Tvoj komšiluk je Dvorovi.", "source_id" => "platforma", "source_label" => "Platforma")]) }] },
                { name: "civic_komsiluk_registered_where", steps: [{ text: "u kom sam komsiluku", read: Contracts::ReadResult.new(status: "empty") }] },
                { name: "civic_mz_contact", steps: [{ text: "Ko je predsjednik mz Janja", read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 12, 9), facts: [fact(id: "mz:janja", text: "Predsjednik MZ Janja: Marko Marković, 055/123-456.", "source_id" => "mz_directory", "source_label" => "Imenik mjesnih zajednica")]) }] },
                { name: "civic_mz_contact_no_area", steps: [{ text: "ko je predsjednik moje mjesne zajednice", read: Contracts::ReadResult.new(status: "ambiguous", warnings: ["area_required"]) }] }
              ]
            end

            def service
              [
                { name: "service_waste_schedule_facts",
                  steps: [{ text: "Kada se odvozi smeće u Dvorovima?", understanding: understanding(action: "ask_information", topic: "waste", entities: { "area_query" => "Dvorovi" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 5), source: { "id" => "eko_dep", "label" => "Eko-dep", "url" => "https://ekodep.example" }, coverage: { "area_slugs" => ["dvorovi"] }, facts: [fact(id: "waste:dvorovi", text: "Smeće se odvozi utorkom i petkom.", "service_day" => "2026-09-15", "source_id" => "eko_dep", "source_label" => "Eko-dep")]) }] },
                { name: "service_stale_read",
                  steps: [{ text: "Ima li prekida struje u Janji?", understanding: understanding(action: "ask_information", topic: "electricity", entities: { "area_query" => "Janja", "query" => "prekid struje" }),
                            read: Contracts::ReadResult.new(status: "stale", checked_at: Time.utc(2026, 9, 10, 5), source: { "id" => "elektro", "label" => "Elektro Bijeljina" }, facts: [fact(id: "elec:janja", text: "Radovi u Janji od 8 do 14.", "starts_at" => "2026-09-11", "source_id" => "elektro", "source_label" => "Elektro Bijeljina")]) }] },
                { name: "service_empty_read",
                  steps: [{ text: "Ima li obustava vode danas?", understanding: understanding(action: "ask_information", topic: "water", entities: { "area_query" => "Bijeljina", "query" => "obustava vode danas" }),
                            read: Contracts::ReadResult.new(status: "empty", checked_at: Time.utc(2026, 9, 14, 6), source: { "id" => "vodovod", "label" => "Vodovod Bijeljina" }) }] },
                { name: "service_unavailable_read",
                  steps: [{ text: "Kakvo je stanje sa grijanjem?", understanding: understanding(action: "ask_information", topic: "heating", entities: { "area_query" => "Centar", "query" => "stanje grijanja" }),
                            read: Contracts::ReadResult.new(status: "unavailable", warnings: %w(source_unreachable)) }] },
                { name: "service_unreviewed_read",
                  steps: [{ text: "Da li je put za Amajlije zatvoren?", understanding: understanding(action: "ask_information", topic: "roads", entities: { "area_query" => "Amajlije" }),
                            read: Contracts::ReadResult.new(status: "unreviewed", warnings: %w(unreviewed_source)) }] },
                { name: "service_conflicting_facts",
                  steps: [{ text: "Radi li most preko Drine?", understanding: understanding(action: "ask_information", topic: "roads", entities: { "area_query" => "Drina" }),
                            read: Contracts::ReadResult.new(status: "unreviewed", warnings: %w(conflicting_current_facts), facts: [fact(id: "road:a", text: "Most je otvoren."), fact(id: "road:b", text: "Most je zatvoren.")]) }] },
                { name: "service_water_level_compaction",
                  steps: [{ text: "Koliki je vodostaj Drine?", understanding: understanding(action: "ask_information", topic: "water_levels", entities: { "query" => "vodostaj Drine" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), validity: { "answer_shape" => "water_level_v1" }, warnings: %w(measurement_delay), facts: [water_fact(id: "wl:drina", text: "Drina kod Bijeljine: 212 cm.", observed_at: "2026-09-14T06:00:00Z"), water_fact(id: "wl:sava", text: "Sava kod Brčkog: 301 cm.", observed_at: "2026-09-14T06:00:00Z")]) }] },
                { name: "service_event_grouping",
                  steps: [{ text: "Ima li radova na vodovodu?", understanding: understanding(action: "ask_information", topic: "water", entities: { "area_query" => "Dvorovi", "query" => "radovi na vodovodu" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), coverage: { "area_slugs" => ["dvorovi"], "requested_relation" => "exact" }, facts: [
                              service_event_fact(id: "ev:1", body: "Radovi na mreži u Dvorovima.", qualifiers: { "time_window" => "od 8 do 14", "scope" => "cijelo naselje" }, "coverage" => { "area_slugs" => ["dvorovi"], "requested_relation" => "exact" }, "service_day" => "2026-09-15"),
                              service_event_fact(id: "ev:2", body: "Zamjena ventila u ulici Svetog Save.", qualifiers: { "time_window" => "od 8 do 14" }, "coverage" => { "area_slugs" => ["dvorovi"], "requested_relation" => "exact" }, "service_day" => "2026-09-16")
                            ]) }] },
                { name: "service_ambiguous_then_area",
                  steps: [
                    { text: "Kada se odvozi smeće?", understanding: understanding(action: "ask_information", topic: "waste", entities: { "query" => "odvoz smeća" }), read: Contracts::ReadResult.new(status: "empty") },
                    { text: "U Dvorovima", understanding: understanding(action: "ask_information", topic: "waste", operation: "continue", entities: { "area_query" => "Dvorovi" }), read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 5), facts: [fact(id: "waste:dvorovi", text: "Smeće se odvozi utorkom i petkom.")]) }
                  ] },
                { name: "service_unsupported_topic_clarify",
                  steps: [{ text: "Šta ima novo?", understanding: understanding(action: "ask_information", topic: "unknown", entities: { "query" => "šta ima novo" }) }] }
              ]
            end

            def registration
              [
                { name: "registration_handoff",
                  steps: [{ text: "Kako da se registrujem?", understanding: understanding(action: "registration", topic: "account", entities: { "query" => "kako da se registrujem" }),
                            handoff: Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "/registracija") }] },
                { name: "registration_phone_purpose",
                  steps: [{ text: "Zašto je potreban broj telefona za registraciju?", understanding: understanding(action: "ask_information", topic: "account", entities: { "query" => "zasto treba telefon za registraciju" }),
                            handoff: Contracts::HandoffResult.new(account_state: "anonymous", next_step: "register", destination: "/registracija") }] },
                { name: "registration_sign_in",
                  steps: [{ text: "Hoću da se prijavim", understanding: understanding(action: "sign_in", topic: "account", entities: {}),
                            handoff: Contracts::HandoffResult.new(account_state: "registered", next_step: "sign_in", destination: "/users/sign_in") }] },
                # "Da li je moj broj potvrđen?" asks for the citizen's OWN
                # verification STATE, and the account family could only ever
                # answer it with a journey: on 14.09, signed in, it returned
                # "ovaj korak je već završen" — byte-identical to what "Koliko
                # sam ljudi pozvao?" returned. It is now selected by the
                # +own_state_verification+ deterministic route and answered as
                # a read, so the step carries a read stub; the handoff stub
                # stays, because the registration port is still what answers
                # if that route ever declines.
                { name: "registration_verification_completed",
                  steps: [{ text: "Da li je moj broj potvrđen?", understanding: understanding(action: "verification", topic: "account", entities: {}),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 9),
                                                            facts: [fact(id: "account:verification", text: "Broj telefona je potvrđen.")]),
                            handoff: Contracts::HandoffResult.new(account_state: "verified", next_step: "verification", destination: "/mi/moj-nalog", completed: true) }] },
                { name: "registration_change_area",
                  steps: [{ text: "Hoću da promijenim komšiluk", understanding: understanding(action: "change_area", topic: "account", entities: {}),
                            handoff: Contracts::HandoffResult.new(account_state: "verified", next_step: "change_area", destination: "/mi/moj-nalog") }] }
              ]
            end

            def catalogue
              [
                { name: "catalogue_budget",
                  steps: [{ text: "Koliki je budžet za 2026?", understanding: understanding(action: "ask_information", topic: "budget", entities: { "query" => "budzet 2026" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 1, 9), source: { "id" => "budzet", "label" => "Budžet Grada", "url" => "https://bijeljina.example/budzet" }, facts: [fact(id: "budget:2026", text: "Budžet za 2026. iznosi 48.000.000 KM.", "source_id" => "budzet", "source_label" => "Budžet Grada", "reviewed_on" => "2026-08-30")]) }] },
                { name: "catalogue_gazette",
                  steps: [{ text: "Gdje je službeni glasnik?", understanding: understanding(action: "ask_information", topic: "gazette", entities: { "query" => "sluzbeni glasnik" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 10, 9), facts: [fact(id: "gazette:7", text: "Službeni glasnik broj 7/2026.", "source_id" => "glasnik", "source_label" => "Službeni glasnik", "source_published_at" => "2026-09-05")]) }] },
                { name: "catalogue_rewards",
                  steps: [{ text: "Koje nagrade mogu dobiti?", understanding: understanding(action: "ask_information", topic: "rewards", entities: { "query" => "nagrade" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 13, 9), facts: [fact(id: "reward:1", text: "Pozivnica za lansiranje — 20 bodova.", "source_id" => "katalog", "source_label" => "Katalog nagrada")]) }] },
                { name: "catalogue_donation",
                  steps: [{ text: "Kako mogu donirati?", understanding: understanding(action: "ask_information", topic: "donation", entities: { "query" => "kako donirati" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 11, 9), facts: [fact(id: "donation:1", text: "Donacije se uplaćuju na račun fondacije.", "source_id" => "fondacija", "source_label" => "Fondacija")]) }] },
                { name: "catalogue_volunteer_empty",
                  steps: [{ text: "Ima li volonterskih akcija?", understanding: understanding(action: "ask_information", topic: "volunteer", entities: { "query" => "volonterske akcije" }),
                            read: Contracts::ReadResult.new(status: "empty", checked_at: Time.utc(2026, 9, 14, 9)) }] },
                { name: "catalogue_public_calls_empty",
                  steps: [{ text: "Ima li otvorenih javnih poziva?", understanding: understanding(action: "ask_information", topic: "public_calls", entities: { "query" => "javni pozivi" }),
                            read: Contracts::ReadResult.new(status: "empty", checked_at: Time.utc(2026, 9, 14, 9)) }] }
              ]
            end

            def control
              [
                { name: "control_thanks", steps: [{ text: "hvala ti puno" }] },
                { name: "control_greeting_cyrillic", steps: [{ text: "Здраво" }] },
                { name: "control_capabilities", steps: [{ text: "Šta sve znaš?" }] },
                { name: "control_help_keyword", steps: [{ text: "pomoc" }] },
                { name: "control_farewell", steps: [{ text: "doviđenja" }] },
                { name: "control_resume_nothing", steps: [{ text: "nastavi" }] },
                { name: "control_clear_conversation", steps: [{ text: "novi razgovor" }] },
                { name: "control_cancel_then_question",
                  steps: [{ text: "Odustajem od prijave. Kako da izvadim rodni list?", read: Contracts::ReadResult.new(status: "empty") }] }
              ]
            end

            def continuity
              [
                { name: "continuity_evidence_source",
                  steps: [
                    { text: "Kada se odvozi smeće u Dvorovima?", understanding: understanding(action: "ask_information", topic: "waste", entities: { "area_query" => "Dvorovi" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 5), coverage: { "area_slugs" => ["dvorovi"] }, facts: [fact(id: "waste:dvorovi", text: "Smeće se odvozi utorkom i petkom.", "service_day" => "2026-09-15")]) },
                    { text: "odakle ti to" }
                  ] },
                { name: "continuity_evidence_date",
                  steps: [
                    { text: "Kada se odvozi smeće u Dvorovima?", understanding: understanding(action: "ask_information", topic: "waste", entities: { "area_query" => "Dvorovi" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 5), coverage: { "area_slugs" => ["dvorovi"] }, facts: [fact(id: "waste:dvorovi", text: "Smeće se odvozi utorkom i petkom.", "service_day" => "2026-09-15")]) },
                    { text: "za koji datum vazi" }
                  ] },
                { name: "continuity_evidence_disagreement",
                  steps: [
                    { text: "Kada se odvozi smeće u Dvorovima?", understanding: understanding(action: "ask_information", topic: "waste", entities: { "area_query" => "Dvorovi" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 5), coverage: { "area_slugs" => ["dvorovi"] }, facts: [fact(id: "waste:dvorovi", text: "Smeće se odvozi utorkom i petkom.", "service_day" => "2026-09-15")]) },
                    { text: "nije tako kod mene" }
                  ] },
                { name: "continuity_evidence_without_prior_answer", steps: [{ text: "odakle ti to" }] },
                { name: "continuity_walking_stop_request",
                  steps: [
                    { text: "Kako do autobuske stanice iz Dvorova?", understanding: understanding(action: "ask_information", topic: "transport", entities: { "query" => "od Dvorova do stanice", "stop" => "Dvorovi" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 7), facts: [transport_stop_fact]) },
                    { text: "kako da pjeske stignem do te stanice",
                      walking_read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 7), facts: [transport_stop_fact.merge("text" => "Pješačenje do stanice Dvorovi (centar): 7 minuta.", "destination" => "https://karta.example/dvorovi")]) }
                  ] },
                { name: "continuity_service_contact_follow_up",
                  steps: [
                    { text: "Ima li obustave vode u Dvorovima?", understanding: understanding(action: "ask_information", topic: "water", entities: { "area_query" => "Dvorovi", "query" => "obustava vode" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), facts: [directory_fact]) },
                    { text: "koji je njihov broj telefona",
                      service_read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), facts: [directory_fact.merge("text" => "Vodovod Bijeljina, telefon 055/210-000.")]) }
                  ] },
                { name: "continuity_procedure_fee_follow_up",
                  steps: [
                    { text: "Kako se vadi uvjerenje o prebivalištu?", understanding: understanding(action: "ask_information", topic: "city_service", entities: { "query" => "uvjerenje o prebivalistu" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 13, 8), facts: [procedure_fact]) },
                    { text: "koliko to kosta",
                      procedure_read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 13, 8), facts: [procedure_fact.merge("text" => "Taksa iznosi 5 KM.")]) }
                  ] },
                { name: "continuity_utility_household_scope",
                  steps: [
                    { text: "Ima li obustave vode u Dvorovima?", understanding: understanding(action: "ask_information", topic: "water", entities: { "area_query" => "Dvorovi", "query" => "obustava vode" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), facts: [fact(id: "water:dvorovi", text: "Obustava vode u Dvorovima od 9 do 13.")]) },
                    { text: "Znači li to da je svaka kuća u Dvorovima bez vode?" }
                  ] },
                { name: "continuity_public_reference_follow_up",
                  steps: [
                    { text: "Ima li obustave vode u Dvorovima?", understanding: understanding(action: "ask_information", topic: "water", entities: { "area_query" => "Dvorovi", "query" => "obustava vode" }),
                      read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), facts: [fact(id: "water:dvorovi", text: "Obustava vode u Dvorovima od 9 do 13.")]) },
                    { text: "A gdje to piše?",
                      reference_read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 6), facts: [fact(id: "water:dvorovi:ref", text: "Objavljeno na stranici Vodovoda, 14.9.2026.")]) }
                  ] },
                { name: "continuity_correction_repair",
                  steps: [
                    { text: "Kada se odvozi smeće u Dvorovima?", understanding: understanding(action: "ask_information", topic: "waste", entities: { "area_query" => "Dvorovi" }),
                      read: Contracts::ReadResult.new(status: "empty") },
                    { text: "pogrešno si me razumjela" }
                  ] }
              ]
            end

            def reports
              [
                { name: "report_problem_start_then_area",
                  steps: [
                    { text: "Smeće nije odvezeno, hoću prijaviti", understanding: understanding(action: "report_problem", topic: "waste", entities: { "description" => "Smeće nije odvezeno" }) },
                    { text: "U Dvorovima", understanding: understanding(action: "report_problem", topic: "waste", operation: "continue", entities: { "area_query" => "Dvorovi" }) }
                  ] },
                { name: "report_status_reference",
                  steps: [{ text: "status moje posljednje prijave", read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 8), facts: [fact(id: "report:42", text: "Prijava BR-2026-0042 je u obradi.", "source_id" => "platforma", "source_label" => "Platforma")]) }] },
                { name: "report_neighborhood_post",
                  steps: [{ text: "Hoću objaviti poruku komšijama", understanding: understanding(action: "neighborhood_post", topic: "neighborhood", entities: { "description" => "Sastanak u petak" }) }] },
                { name: "report_neighborhood_information",
                  steps: [{ text: "Šta ima u mom komšiluku?", understanding: understanding(action: "neighborhood_information", topic: "neighborhood", entities: { "area_query" => "Dvorovi" }),
                            read: Contracts::ReadResult.new(status: "ok", checked_at: Time.utc(2026, 9, 14, 8), coverage: { "scope" => "public_neighborhood_activities", "area_labels" => ["Dvorovi"], "notices" => { "area_label" => "Dvorovi" } }, facts: [
                              fact(id: "nb:notice", text: "Radovi na parku počinju u ponedjeljak."),
                              { "id" => "nb:report", "kind" => "area_public_report", "text" => "Prijavljena rupa u ulici Svetog Save.", "source_id" => "platforma", "source_label" => "Platforma" },
                              { "id" => "nb:activity", "kind" => "neighborhood_activity", "text" => "Volonterska akcija čišćenja.", "source_id" => "platforma", "source_label" => "Platforma", "coverage" => { "activity_type" => "volunteer" } }
                            ]) }] }
              ]
            end
          end
          # rubocop:enable Layout/LineLength, Style/HashSyntax, Layout/FirstArrayElementIndentation, Metrics/ParameterLists
        end
      end
    end
  end
end

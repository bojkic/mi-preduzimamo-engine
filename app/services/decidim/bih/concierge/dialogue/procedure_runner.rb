# frozen_string_literal: true

require "i18n"
require "uri"
require "date"
require_relative "state_store"
require_relative "answer_context"
require_relative "answer_continuation"
require_relative "stage_timing"
require_relative "time_text"
require_relative "procedure_question"
require_relative "service_follow_up_question"
require_relative "public_activity_continuation"
require_relative "public_activity_place"
require_relative "text_predicates"
require_relative "transport_follow_up_question"
require_relative "transport_question_route"
require_relative "public_catalog_empty_answer"
require_relative "fact_renderer"
require_relative "resolution"
require_relative "dead_end"
require_relative "checked_zero"
require_relative "utility_scope_question"
require_relative "question_facet"
require_relative "topic_menu"
require_relative "account_question"
require_relative "place_grounding"
require_relative "../responder"
require_relative "../../text"
require_relative "procedures/report_problem"
require_relative "procedures/registration"
require_relative "procedures/city_service"
require_relative "procedures/komsiluk"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # No persistence or model calls here. Every turn receives fresh trusted
        # scope; only the coordinator may CAS the returned semantic state.
        class ProcedureRunner
          Result = Data.define(:state, :reply, :resolution, :fact_ids, :handoff_offered, :handoff_completed, :diagnostics) do
            # Bounded per-turn diagnostics (tokens and counts, never text) for
            # synthetic runs. Optional: the coordinator's control and failure
            # results carry none, and nothing persisted depends on them.
            def initialize(state:, reply:, resolution:, fact_ids:, handoff_offered:, handoff_completed:, diagnostics: nil)
              super
            end
          end
          REGISTRATION_ACTIONS = %w(registration sign_in link_account verification change_area preferences).freeze
          NEIGHBORHOOD_ACTIONS = %w(neighborhood_information neighborhood_post choose_area).freeze
          CONTROL_ACTIONS = %w(help safety cancel).freeze
          RESUME_COMMANDS = ["nazad", "nastavi", "vrati se", "back", "continue", "назад", "настави", "врати се"].freeze
          # Tariffs, schedules, catalogues and public data: a fact from a
          # reviewed source needs no "not a confirmation of conditions on the
          # ground" footer. Utilities, water levels, weather, civil protection
          # and police keep it.
          GREEN_TOPICS = %w(waste parking transport budget gazette city_service goodwill rewards volunteer participation community donation).freeze
          # Per-topic answer intents for information reads, so analytics stop
          # collapsing most turns into "service". Every value is in
          # AnswerIntents::VALUES; anything else stays "service".
          TOPIC_ANSWER_INTENTS = {
            "waste" => "waste", "budget" => "budget", "gazette" => "gazette", "donation" => "donation",
            "goodwill" => "goodwill", "rewards" => "goodwill", "volunteer" => "volunteer_guidance",
            "participation" => "participation_guidance", "community" => "participation_guidance"
          }.freeze
          ENGLISH_EVIDENCE_FOLLOW_UPS = [
            "where did you get that", "what is the source", "what date is this for", "when does this apply",
            "that is not true where i am", "that is not the case here"
          ].freeze
          STABLE_IDENTIFIER = /\A[A-Za-z0-9][A-Za-z0-9:._-]{0,159}\z/
          # A reviewed contact a host may hand back as the next step for an
          # unsupported topic: digits with the usual separators, nothing else.
          NEXT_STEP_PHONE = %r{\A\+?\d[\d\s/().-]{4,31}\z}
          DIAGNOSTIC_TRANSITIONS = %w(start continue correct switch).freeze
          # Slots an opaque draft actually depends on. A confirmation the model
          # decorates with an unrelated slot must not destroy the reference the
          # citizen is looking at (the "Potvrdi slanje <ref>" chip).
          DRAFT_SLOTS = %w(description category area_query area_slug street address).freeze
          # Slots whose value the citizen normally says LITERALLY. The model is
          # shown the retained entity VALUES (Understand#suspended_projection),
          # so it can re-emit a retained street as if it had just been spoken.
          # A candidate on one of these keys that equals what is already stored
          # and does not appear in this turn's text is an echo, not a new fact.
          LITERAL_ENTITY_KEYS = %w(area_query area_slug street address stop via_stop route reference category time_expression date).freeze
          # WHERE a location lives. These are the slots a turn that names its
          # own place must not inherit one in. Deliberately narrower than
          # LITERAL_ENTITY_KEYS: a category, a reference or a date is not a
          # place, and a deterministic route legitimately re-supplies one
          # across a task switch ("A koliko za registraciju?" keeps
          # category=earn). There is no "zone" slot — a zone is named in the
          # question itself, which is why a stale street could outrank it.
          CARRIED_LOCATION_KEYS = %w(area_query area_slug street address stop).freeze
          # Case endings in Serbian change the tail of a word, never its stem.
          # Two characters is what "Nušićeva" and "Nušićevoj" differ by.
          STEM_TAIL = 2
          # The render path a turn took, for bounded diagnostics only. A closed
          # enum: anything else is reported as "none" rather than leaked.
          RENDER_PATHS = %w(available empty ambiguous unavailable conflicting clarify none).freeze
          # "not X, but Y" — the contrastive correction that is not a cancel.
          ACCOUNT_CORRECTION = /\b(?:nego|vec|umjesto|umesto|instead|rather|but)\b/

          # Closed citizen follow-ups are interpreted before model output. An
          # existing public read and its explicit place are enough context;
          # a model paraphrase of the previous query is not an intent gate.
          def self.public_activity_continuation_input(text:, state:, locale:)
            refinement = PublicActivityContinuation.call(text:, state:, locale:)
            return refinement if refinement

            return unless text.is_a?(String) && text.length <= 160 && public_activity_context?(state)

            if state["pending_slot"] == "area_query" && (area = qualified_activity_area(text))
              return Contracts::Understanding.parse(action: "ask_information", topic: state.fetch("topic"), entities: { "area_query" => area },
                                                    operation: "continue", needs_clarification: false, secondary: nil, locale:)
            end
            return unless %w(neighborhood participation).include?(state["topic"]) && citizen_activity_area?(state)
            return unless Text.fold(text).match?(/\A(?:
              a[ ](?:neke?[ ])?(?:volonterske[ ](?:akcije|aktivnosti)|volontiranje)|
              (?:and|what[ ]about)[ ](?:some[ ])?volunteer(?:ing)?[ ](?:activities|opportunities)
            )\z/x)

            Contracts::Understanding.parse(action: "ask_information", topic: "volunteer", entities: { "query" => text },
                                           operation: "continue", needs_clarification: false, secondary: nil, locale:)
          end

          # THE deterministic cancellation vocabulary, in one place. The
          # negated-action half only counts in the first clause: "treba mi
          # službena stranica toplane, ne prijava problema" is a contrastive
          # correction of a POSITIVE request, and cancelling it discards what
          # the citizen actually asked for.
          def self.cancellation_wording?(text)
            folded = Text.fold(text.to_s).gsub(/[^a-z0-9\s]/, " ").split.join(" ")
            return false if folded.empty?

            Responder::CANCEL_COMMANDS.include?(folded.split.first) || TextPredicates.cancel_command?(folded) ||
              TextPredicates.decorated_cancel?(folded) ||
              TextPredicates.cancel_action?(folded, Responder::CANCEL_ACTION_PATTERN) ||
              folded.match?(/\b(?:do not|don t)\s+(?:publish|submit|continue|link|register)\b/)
          end

          # "vrati se" is in RESUME_COMMANDS; "Vrati se na ono za smeće, koji
          # dan si rekla?" is not, and used to start an EMPTY new task while the
          # suspended one still held the citizen's street. Same move, one
          # sentence longer.
          def self.resume_request?(text, state)
            return false unless state.is_a?(Hash) && state["suspended_task"]

            RESUME_COMMANDS.include?(text.to_s.strip.downcase) || TextPredicates.resume_request?(text)
          end

          def self.public_activity_context?(state)
            state["active_task"] == "ask_information" && %w(neighborhood participation volunteer community).include?(state["topic"]) &&
              !state["draft"] && state.dig("prior_evidence", "kind") != "member_board" &&
              !TextPredicates.board_context?(Text.fold(state.dig("entities", "query")))
          end

          def self.citizen_activity_area?(state)
            keys = %w(area_query area_slug street address).select { |key| !state.dig("entities", key).to_s.empty? }
            keys.intersect?(%w(area_query area_slug)) && keys.all? { |key| %w(citizen corrected).include?(state.dig("entity_provenance", key)) }
          end

          def self.qualified_activity_area(text)
            folded = Text.fold(text)
            return unless TextPredicates.qualified_area?(folded)

            text.strip.sub(/[.!?]\z/, "")
          end

          # +capabilities+ is the host's topic inventory (responds to
          # +supported?(topic)+ and, optionally, +next_step_for(topic)+). Nil
          # keeps the pre-gate behaviour: every topic is read.
          def initialize(read_port:, registration_port:, destinations:, capabilities: nil)
            @read_port = read_port
            @registration_port = registration_port
            @capabilities = capabilities
            @destinations = destinations.transform_keys(&:to_s).transform_values do |path|
              raise Contracts::Invalid, "Expected local application destination" unless self.class.safe_path?(path)

              path.dup.freeze
            end.freeze
          end

          # The rule lives with the renderer that prints URLs; this stays the
          # name the runner and its tests already use.
          def self.safe_path?(value) = FactRenderer.safe_path?(value)

          def call(understanding:, state:, context:, message: nil)
            input = Contracts::Understanding.parse(understanding.to_h)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: input).call
          end

          # Deterministic retained-evidence replies deliberately bypass
          # Understanding. They preserve the current task rather than treating
          # a source/date question as a new citizen request.
          def prior_evidence_follow_up(kind:, state:, context:, message: nil)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: nil).prior_evidence_follow_up(kind:)
          end

          def transport_walking_follow_up(state:, context:, message:)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: nil).transport_walking_follow_up
          end

          def procedure_fee_follow_up(state:, context:, message:)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: nil).procedure_fee_follow_up
          end

          def service_follow_up(state:, context:, message:)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: nil).service_follow_up
          end

          def public_information_follow_up(state:, context:, message:)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: nil).public_information_follow_up
          end

          # The state a turn the LEGACY read adapter answered should leave
          # behind. That path used to write nothing at all, so the next turn was
          # classified against the task the citizen had already moved on from.
          # It reuses the ordinary validated transition — suspension, draft and
          # entity rules included — and returns nil when the transition is
          # refused, which means "keep the saved state as it is".
          def secondary_state(understanding:, state:, context:, message: nil)
            input = Contracts::Understanding.parse(understanding.to_h)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: input).secondary_state
          end

          # A presentation operation on an answer produced outside the budgeted
          # renderer (the legacy adapter). Same facts, same source
          # qualification, materially shorter. No read and no model call.
          def shorten_reply(answer, state:, context:, message: nil, level: nil)
            validated = StateStore.new.validate(context:, state:)
            Turn.new(read_port: @read_port, registration_port: @registration_port, destinations: @destinations, capabilities: @capabilities,
                     state: validated, context:, message:, understanding: nil).shorten_reply(answer, level:)
          end

          # Request-local execution object: never retain actor, locale, or facts
          # on a memoized application service across Puma requests.
          class Turn
            attr_reader :state, :context, :message

            def initialize(read_port:, registration_port:, destinations:, state:, context:, message:, understanding:, capabilities: nil) # rubocop:disable Metrics/ParameterLists
              @read_port = read_port
              @registration_port = registration_port
              @destinations = destinations
              @capabilities = capabilities
              @read_count = 0
              @capability_gate = "skipped"
              @supplied_entity_keys = []
              @dropped_entity_keys = []
              @render_path = "none"
              @read_status = nil
              @read_warning_codes = 0
              @draft_replaced = false
              @state = state.merge("entities" => state.fetch("entities").dup, "entity_provenance" => state.fetch("entity_provenance").dup)
              # The question the SAVED task was about, captured before this
              # turn's candidates are merged over it.
              @previous_query = state.fetch("entities")["query"].to_s
              # The entity bag as this turn FOUND it, before a task switch can
              # reset it. It is what the echo fence compares against; see
              # #echoed_entity?.
              @entry_entities = state.fetch("entities").dup
              # The slot the LAST turn asked for, captured before this turn's
              # rendering clears it. A refusal uses it to know it has already
              # asked, and asking twice is the loop the repair exists to end.
              @entry_pending_slot = state["pending_slot"]
              @context = context
              @message = message
              @understanding = understanding
            end

            def call
              guarded = guarded_reply
              return guarded if guarded

              normalize_neighborhood_continuation
              normalize_literal_public_activity_place
              unresolved = unresolved_understanding_reply
              return unresolved if unresolved

              @trusted_transport_query = trusted_transport_continuation_query
              transition
              guarded = post_transition_reply
              return guarded if guarded

              repaired = repair_reply
              return repaired if repaired

              conceptual = conceptual_transport_reply
              return conceptual if conceptual

              missing = requested_missing_detail
              return missing if missing

              facet = facet_reply
              return facet if facet

              procedure.call(self)
            end

            def t(key, locale: state.fetch("locale"), **values)
              I18n.t("decidim.bih.dialogue.#{key}", locale:, **values, raise: true)
            end

            # Stored evidence stays ISO 8601; the citizen reads a human time.
            def human_time(value, locale: state.fetch("locale"))
              TimeText.call(value, locale:, now: context.now)
            end

            def green_topic? = GREEN_TOPICS.include?(topic)

            def entities = state.fetch("entities")

            def action = state.fetch("active_task")

            def topic = state.fetch("topic")

            def public_activity_refinement? = !!@public_activity_refinement

            def location = message.respond_to?(:dialogue_location) ? message.dialogue_location : nil

            def destination(key) = @destinations.fetch(key.to_s)

            # Asked by a procedure BEFORE it collects any detail: does the host
            # have a reader or a reviewed source family for this topic? Without
            # an inventory every topic is supported (the pre-gate behaviour).
            def capability_supported?
              return true unless @capabilities

              if @capabilities.supported?(topic)
                @capability_gate = "supported"
                true
              else
                @capability_gate = "unsupported"
                false
              end
            end

            # An honest limit with one next step; no slot is left pending.
            def unsupported_topic
              finish(t("unsupported_topic", next_step: unsupported_next_step), resolution: "unsupported")
            end

            # Bounded facts about how this turn was answered, for synthetic
            # runs (TurnDiagnostics). Tokens and counts only — never text.
            def diagnostics
              { "transition" => transition_token, "read_count" => @read_count,
                "missing_field_reason" => @missing_field_reason, "capability_gate" => @capability_gate,
                "supplied_entity_keys" => @supplied_entity_keys.sort.freeze,
                "retained_entity_keys" => (entities.keys - @supplied_entity_keys).sort.freeze,
                "dropped_entity_keys" => @dropped_entity_keys.uniq.sort.freeze,
                "read_status" => @read_status, "read_warning_codes" => @read_warning_codes,
                "render_path" => RENDER_PATHS.include?(@render_path) ? @render_path : "none", "facet" => @facet_token,
                "draft_replaced" => @draft_replaced }.freeze
            end

            def has_location?
              location || %w(area_query area_slug street address).any? { |key| !entities[key].to_s.strip.empty? }
            end

            # What the reader is asked. The governing rule: THE CITIZEN'S OWN
            # CURRENT WORDS ARE THE QUESTION. A model paraphrase stands only
            # where the citizen's turn actually supplied slots of its own, and
            # even then not for a place-bearing parking/water-level/journey
            # question, where the paraphrase drops the place.
            #
            # Before this, an entity-free follow-up sent the reader either the
            # PREVIOUS question or — for water/electricity/heating — the model's
            # query, which is "" on such a turn. Either way the reader was
            # handed the same inputs and honestly returned the same answer, four
            # turns running.
            def current_question_entities
              return entities if @resumed_task || read_follow_up_kind
              return presentation_question_entities if presentation_request?
              return entities.merge("query" => @trusted_transport_query) if @trusted_transport_query
              return entities.merge("query" => text) if literal_text_question? || entity_free_question? || facet_shift?
              return entities unless ServiceQuestion::TOPICS.include?(topic) || transport_pricing_context?

              # The saved task may retain an earlier publication question.
              # Only an explicit task resume may reuse it for a source read.
              entities.merge("query" => understanding.entities.fetch("query", ""))
            end
            alias service_question_entities current_question_entities

            # Public reads may answer the literal citizen question while keeping
            # a shorter model query in entities. Re-reading for brevity must use
            # the validated question actually answered, including its places,
            # rather than that lossy query. The reader rechecks scope and facts.
            def presentation_question_entities
              return entities unless action == "ask_information" && !state["draft"]

              retained = AnswerContext.normalize(state[AnswerContext::KEY], now: context.now, state_expires_at: state.fetch("expires_at"))
              return entities unless retained && retained.values_at("kind", "action", "topic", "subject") == ["core_read", action, topic, "#{action}:#{topic}"]

              entities.merge("query" => retained.fetch("anchor"))
            end

            # Only a server-recomputed continuation may carry the prior nearest-stop
            # or fare subject. Model paraphrases never earn this exception by a flag or
            # by naming the topic: action, topic and query must exactly match
            # the deterministic resolver on pre-transition state/current text.
            def trusted_transport_continuation_query
              if understanding && [understanding.action, understanding.topic] == %w(ask_information transport)
                retained_query = TransportFollowUpQuestion.nearest_location_query(text, state:) ||
                                 TransportFollowUpQuestion.calendar_continuation_query(text, state:)
                return retained_query if retained_query && retained_query == understanding.entities["query"]
              end
              return unless transport_fee_continuation?

              follow_up = message.respond_to?(:follow_up) && message.follow_up == true
              read = AnswerContinuation.resolve(text:, state:, follow_up:)&.read
              return unless read && read.values_at(:action, :topic) == %w(ask_information transport)

              query = read.fetch(:entities).fetch("query")
              query if query == understanding.entities["query"]
            end

            def transport_fee_continuation?
              understanding && understanding.action == "ask_information" && understanding.topic == "transport" &&
                !state["draft"] && state.values_at("active_task", "topic") == %w(ask_information transport) &&
                state.dig(AnswerContext::KEY, "facet") == "fee"
            end

            # A model-supplied query can repeat the old "here" question even
            # when this turn names the requested zone colour, river or journey.
            # The host resolves journey spans, local dates, calendar changes and
            # landmarks from the actual citizen text. Elliptical transport turns
            # need this too: a model query can omit their only date or landmark.
            def literal_text_question?
              transport = topic == "transport" && text.length <= 1000
              topic == "parking" || (topic == "water_levels" && text.length <= 160) || transport
            end

            # The elliptical follow-up: the citizen supplied no slot this turn,
            # so their sentence IS the question. Without this the reader was
            # given the previous question and re-ran the previous read.
            def entity_free_question?
              @supplied_entity_keys.empty? && usable_question_text?
            end

            # The citizen asked something DIFFERENT about the same topic — a
            # fee instead of a day, a phone number instead of a schedule. The
            # model may still have attached a slot to that turn, so it is not
            # entity-free; it is nonetheless a new question, and answering it
            # with the retained one is how four identical replies happen.
            def facet_shift?
              return false unless usable_question_text? && !@previous_query.strip.empty?

              current = QuestionFacet.call(text)
              !current.nil? && current != QuestionFacet.call(@previous_query)
            end

            def usable_question_text?
              text.length.between?(1, 160) && text.match?(/\p{L}/)
            end

            def transport_pricing_context?
              # A price question is not a journey destination. Drop only that
              # stale free-text slot on the next turn; keep real destinations
              # and the explicit suspended-task resume contract unchanged.
              topic == "transport" && Text.fold(entities["query"]).match?(/\b(?:cijen\w*|cen[aeu]|cjenovnik|cenovnik|tarif\w*|koliko|fares?|prices?|costs?|how much)\b/)
            end

            # WHAT this turn asks about the topic (QuestionFacet), from the
            # citizen's own current words.
            def facet
              return @facet if defined?(@facet)

              @facet = QuestionFacet.call(current_question_entities["query"])
              @facet_token = @facet
              @facet
            end

            # A reviewed contact card answers a contact/website/operator/hours
            # question. Asking "in which neighbourhood?" first — which is what a
            # heating contact question used to get — is never right for one.
            def facet_reply
              return unless QuestionFacet.directory?(current_question_entities["query"])
              return unless ServiceQuestion::TOPICS.include?(topic) && !has_location?
              return unless procedure == Procedures::CityService && capability_supported?

              render_read(read(action: "ask_information", entities: current_question_entities))
            end

            # Two escapes from the clarification budget, for the two cases
            # where spending it punishes the citizen for OUR confusion:
            #
            #   +charge: false+  — a refused transition. We declined to move;
            #     nothing the citizen did was unclear, so nothing is spent.
            #   +restart: true+  — an explicit repair. It starts the budget at
            #     zero instead of inheriting whatever the citizen had already
            #     spent answering slot questions (which is how "Rekla sam ti
            #     već" arrived at the clarification limit, a8c07 t4). Repeated
            #     repairs still escalate — from the repair, not from before it.
            # rubocop:disable Metrics/ParameterLists
            def clarify(slot, key, charge: true, restart: false, chips: [], **values)
              @missing_field_reason = key
              @render_path = "clarify"
              count = clarification_count_for(slot, charge:, restart:)
              repeated_slot = state["pending_slot"] == slot
              state["pending_slot"] = slot
              state["clarification_count"] = [count, 2].min
              return finish(t("clarification_limit", url: destination("support")), resolution: "handoff", offered: true) if count > 2

              if topic == "transport" && slot == "stop" &&
                 (presentation_request? || Text.fold(text).match?(/\b(?:odakle|gdje|gde)\b.*\bulazim\b/))
                answer = "#{t("transport_boarding_unresolved")}\n\n#{t(key, **values)}"
                return finish(answer, resolution: "clarification", chips:)
              end
              repeated_key = "#{key}_again"
              key = repeated_key if repeated_slot && I18n.exists?("decidim.bih.dialogue.#{repeated_key}", state.fetch("locale"))
              finish(t(key, **values), resolution: "clarification", chips:)
            end
            # rubocop:enable Metrics/ParameterLists

            def clarification_count_for(slot, charge:, restart:)
              return state.fetch("clarification_count") unless charge
              return state.fetch("clarification_count") + 1 if state["pending_slot"] == slot

              restart ? 0 : 1
            end

            def read(action: self.action, topic: self.topic, entities: self.entities, location: self.location, locale: state.fetch("locale"))
              return Contracts::ReadResult.new(status: "unavailable", warnings: ["deadline_exceeded"]) if context.deadline&.expired?

              count_read
              result = @read_port.call(action:, topic:, entities:, context:, locale:, location:)
              raise Contracts::Invalid, "Typed read result required" unless result.is_a?(Contracts::ReadResult)

              retain_supplied_activity_area(result)
              retain_transport_query_entities(result, query: entities["query"])
              without_unsaid_street_claim(result)
            end

            # "Znam ulicu iz pitanja, ali izvor ne objavljuje obuhvat po
            # ulicama" is an honest caveat only while the question HAD a street.
            # A place slot survives the turn that supplied it, so the sentence
            # kept firing on "A struja?" and on "zasto?" — claiming knowledge of
            # a street those turns never contained. When the read widened
            # city-wide without a street from this turn, that is a different
            # situation and gets no sentence at all: the city-wide scope is
            # already recorded in the result's coverage.
            UNSAID_STREET_WARNING = "street_coverage_not_published_by_source"

            def without_unsaid_street_claim(result)
              return result if @supplied_entity_keys.intersect?(%w(street address))
              return result unless result.warnings.include?(UNSAID_STREET_WARNING)

              result.with(warnings: result.warnings - [UNSAID_STREET_WARNING])
            end

            def render_read(result)
              StageTiming.measure("rendering") { render_read_result(result) }
            end

            def render_read_result(result)
              record_read_diagnostics(result)
              if topic == "transport" && result.status == "empty" && entities["stop"] &&
                 result.warnings.intersect?(%w(origin_not_in_reviewed_timetable reviewed_origin_stop_required))
                return clarify("stop", "supplied_stop_unresolved", stop: entities.fetch("stop"))
              end
              clear_pending_slot unless result.status == "ambiguous"
              return render_conflicting_read(result) if conflicting_read?(result)
              return clarify("area_query", "ask_parking_zone") if parking_zone_required?(result)
              return finish(neighborhood_summary_text(result, []), resolution: "answered") if result.status == "empty" && public_neighborhood_summary?(result)

              case result.status
              when "ok", "stale" then render_available_read(result)
              when "ambiguous" then clarify_read_ambiguity(result)
              when "not_authorized" then finish(t("not_authorized", url: destination("account")), resolution: "handoff", offered: true)
              when "empty" then render_empty_read(result)
              else render_unavailable_read(result)
              end
            end

            def render_unavailable_read(result)
              key = if unverified_transport_day?(result)
                      "transport_calendar_unverified"
                    else
                      result.status == "unreviewed" ? "unreviewed" : "unavailable"
                    end
              finish(with_result_evidence(t(key, url: destination("support")), result), resolution: "source_unavailable")
            end

            def unverified_transport_day?(result)
              return false unless topic == "transport" && %w(unavailable unreviewed).include?(result.status)
              return false if result.warnings.include?("deadline_exceeded")

              result.warnings.intersect?(%w(unsupported_service_day service_calendar_requires_review))
            end

            # A scoped zero-result answer is an ANSWER; falling back to the
            # "no verified data" refusal is not. Which of the two this is is
            # Resolution's decision, made in one place.
            def render_empty_read(result)
              if topic == "transport" && result.warnings.include?("no_feasible_journey_within_transfer_limit")
                return finish(with_result_evidence(transport_no_feasible_answer(result), result), resolution: Resolution::UNSUPPORTED)
              end
              if topic == "transport" && result.warnings.include?("no_departures_published_for_service_day")
                return finish(with_result_evidence(t("transport_no_published_departures"), result), resolution: Resolution::UNSUPPORTED)
              end

              if topic == "transport" && (warning = (result.warnings & %w(transport_live_status_unavailable transport_accessibility_unverified)).first)
                return finish(with_result_evidence(t(warning), result), resolution: Resolution::UNSUPPORTED)
              end

              return own_reports_empty_answer(result) if own_reports_empty?(result)

              complete = PublicCatalogEmptyAnswer.call(result:, topic:, locale: state.fetch("locale"))
              return finish(with_result_evidence(complete, result), resolution: Resolution.empty_read(complete: true)) if complete

              refuse(result, key: "no_match", resolution: Resolution.empty_read(complete: false))
            end

            # THE one exit for a refusal that carries no answer, so that every
            # dead end leaves with a next step and none of them leaves with a
            # different MEANING than it had before.
            #
            # Two next steps, in this order:
            #
            #   1. the question that unlocks the read. Only when a missing
            #      place is what the reader lacked (Dialogue::DeadEnd decides),
            #      and only once — a place already supplied is never asked for
            #      again. This turn genuinely ends as a CLARIFICATION: it asks,
            #      it keeps the pending slot, and the citizen can finish it.
            #   2. the responsible destination. The reviewed publisher this
            #      read already cites, named as the place that holds the
            #      record — or, when the citation is ours or absent, the
            #      support route. Never nothing.
            #
            # +resolution+ is passed in unchanged. Naming where to go does not
            # turn a refusal into an answer or into a hand-off: it would move
            # the turn out of Resolution::UNRESOLVED and back into the success
            # bucket, which is exactly the accounting Task 9b removed.
            def refuse(result, key:, resolution:)
              slot = DeadEnd.unlocking_slot(topic:, warnings: result.warnings, has_location: has_location?, pending_slot: @entry_pending_slot)
              return clarify(slot, "ask_#{slot}") if slot

              claim = resolution == Resolution::UNSUPPORTED ? CheckedZero.claim(result.warnings) : nil
              return checked_zero_answer(result, claim) if claim

              finish(with_next_step(with_result_evidence(t(key), result), result), resolution:)
            end

            # The read's own warnings already say the source WAS reached and
            # holds nothing for the asked area and period, so the turn has
            # ANSWERED — negatively, with its scope named underneath. Printing
            # "Za ovo nemam provjeren podatak" on top of that made one reply
            # carry two contradictory typed outcomes; the checked-zero sentence
            # is the true one, so it becomes the answer and the refusal is not
            # emitted at all.
            #
            # No next step: R3 gives a dead end one because something is
            # missing. Nothing is missing here — the citizen asked, the source
            # was read, and the verified answer is none.
            #
            # Only the UNSUPPORTED refusal is redirected here. A stale source,
            # unreviewed evidence, an unavailable read and an unauthorized read
            # keep their own labels and their own copy: a checked-zero claim on
            # a source we could not trust is not an answer.
            def checked_zero_answer(result, code)
              sentence = fact_renderer.warning_sentence(code)
              finish(with_result_evidence(sentence, result, omit_warning: sentence),
                     resolution: Resolution.empty_read(complete: false, checked_zero: true))
            end

            # The refusal's next step, appended AFTER the provenance block: the
            # source that was searched and the destination to take this to are
            # two different claims, and running them together is what made the
            # old reply read as "the answer is in this PDF".
            #
            # Which destination is a property of the source, not of the topic:
            #
            #   an EXTERNAL reviewed publisher (Komunalac, Vodovod, the city)
            #     -> name them and say to check there. They hold the record;
            #        we do not. The link is already printed above.
            #   anything else, including our own platform and a read that cites
            #     no source at all -> the support route, which is ours to
            #        answer. Never nothing.
            #
            # Deliberately costs no read: naming where to go must not spend a
            # second source lookup, a second entity-retention pass or a second
            # line in the turn's read diagnostics.
            def with_next_step(answer, result)
              name = fact_renderer.external_source_name(result)
              step = if name
                       t("dead_end_source", source: name, url: destination("support"))
                     else
                       t("dead_end_support", url: destination("support"))
                     end
              "#{answer}\n\n#{step}"
            end

            def record_read_diagnostics(result)
              @read_status = result.status
              @read_warning_codes = result.warnings.length
              @render_path = case result.status
                             when "ok", "stale" then "available"
                             when "ambiguous" then "ambiguous"
                             when "empty" then "empty"
                             when "unavailable", "not_authorized" then "unavailable"
                             else conflicting_read?(result) ? "conflicting" : "unavailable"
                             end
            end

            def conflicting_read?(result)
              result.status == "unreviewed" && result.warnings.include?("conflicting_current_facts")
            end

            def render_conflicting_read(result)
              assertions = validated_facts(result).first(2).map { |fact| render_fact(fact) }.join("\n\n")
              answer = [t("read_warning_conflicting_facts"), assertions].reject(&:empty?).join("\n\n")
              finish(answer, resolution: "source_unavailable")
            end

            def parking_zone_required?(result)
              topic == "parking" && result.status == "ambiguous" && result.warnings.include?("parking_zone_required")
            end

            def render_duplicate_facts(result)
              StageTiming.measure("rendering") do
                facts = validated_facts(result)
                answer = facts.map { |fact| render_fact(fact) }.join("\n\n")
                answer = with_source_language_note(answer) unless facts.empty?
                [with_result_evidence(answer, result, include_source: facts.empty?), fact_ids(facts)]
              end
            end

            def handoff(action: self.action)
              result = @registration_port.call(action:, context:, locale: state.fetch("locale"))
              validate_handoff!(result)

              return unavailable_handoff if handoff_unavailable?(result)
              raise Contracts::Invalid, "Unsafe handoff destination" unless safe_url?(result.destination)

              finish_handoff(result)
            end

            # The tail of a validated hand-off, shared with the account
            # explanations so that falling back to the real next step costs no
            # second port call.
            def finish_handoff(result)
              finish(handoff_answer(result),
                     resolution: result.completed ? "answered" : "handoff",
                     offered: !result.completed,
                     completed: result.completed)
            end

            def registration_information_request?
              return true if (action == "ask_information" && topic == "account") ||
                             (understanding.action == "ask_information" && understanding.topic == "account")

              # The model's action label is not the question. A citizen already
              # inside the account family who asks something AccountQuestion
              # recognises is answered, instead of being handed the register
              # link again — which is what 15 of 37 rated account turns got.
              account_family? && !account_facet.nil?
            end

            def account_family?
              REGISTRATION_ACTIONS.include?(action) || topic == "account"
            end

            # The citizen's OWN words decide which account journey this is; the
            # model's rewritten query is only consulted when their words carry
            # no recognisable journey. Bounded to this turn either way — never a
            # query retained from an earlier account explanation.
            def account_facet
              return @account_facet if defined?(@account_facet)

              @account_facet = AccountQuestion.facet(text) || AccountQuestion.facet(understanding.entities["query"])
            end

            def registration_information
              facet = account_facet
              return account_menu unless facet

              route = AccountQuestion::ROUTES[facet]
              return handoff(action: route) if route

              result = account_handoff(facet)
              return unavailable_handoff if handoff_unavailable?(result)
              raise Contracts::Invalid, "Unsafe handoff destination" unless safe_url?(result.destination)

              answer = account_answer(facet, result)
              # A facet that cannot be answered truthfully (an account that is
              # not in the state it claims, an unreadable points schedule) falls
              # back to the real next step rather than to an invented sentence.
              return finish_handoff(result) unless answer

              # An observed existing account is not proof that the citizen has
              # just accepted terms or changed an optional preference in chat.
              clear_pending_slot if state["pending_slot"] == "query"
              finish(answer, resolution: "answered", offered: true, preserve_task: true)
            end

            # The menu, ONCE. A second unresolved account turn gets a working
            # route instead of the same sentence again: the identical menu came
            # back twice in a row in six rated conversations, once immediately
            # after the citizen answered "Ništa od toga".
            def account_menu
              return handoff(action: account_menu_route) if state["pending_slot"] == "query" && state.fetch("clarification_count").positive?

              clarify("query", "account_help_clarify", chips: account_menu_chips)
            end

            def account_menu_route
              REGISTRATION_ACTIONS.include?(action) ? action : "registration"
            end

            # Each chip's LABEL is also what it sends, and every label is an
            # utterance AccountQuestion resolves on its own. That is what makes
            # the tapped choice and the typed sentence the same thing.
            def account_menu_chips
              %w(register sign_in verify terms).map do |choice|
                label = t("account_help_chip_#{choice}")
                { label:, send: label }
              end
            end

            # THE top-level menu ladder, in one place because two callers walk
            # it: an unresolved understanding and a help/unknown city-service
            # turn. Before this, the second caller offered the menu with no
            # chips and then offered it AGAIN — the menu appeared in seven
            # separate re-test turns and carried quick replies in none of them,
            # while the account clarifier in the same release carried four.
            #
            # The ladder never repeats itself:
            #
            #   the citizen already named the service option -> ask which
            #     service. They answered the menu; re-offering it is the loop.
            #   a menu has already been spent on this slot -> ask which service.
            #   otherwise -> the menu, with the four tappable openings.
            #
            # The third turn still reaches clarification_limit through the
            # ordinary budget; nothing here widens it.
            def topic_clarification(slot = "query")
              step = state[StateStore::TOPIC_MENU_KEY].to_i
              # Naming one of the four options IS answering the menu, so it
              # never gets the menu back — it gets the option's own question.
              step = [step, 1].max if TopicMenu.service_choice_text?(text)
              state[StateStore::TOPIC_MENU_KEY] = [step + 1, StateStore::TOPIC_MENU_STEPS].min
              case step
              when 0 then clarify(slot, "clarify", chips: topic_menu_chips)
              when 1 then clarify(slot, "ask_query")
              else finish(t("clarification_limit", url: destination("support")), resolution: "handoff", offered: true)
              end
            end

            # The same rule one level up: the opening menu names four things
            # and, across 23 occurrences in the 14.09 corpus, offered no way to
            # tap any of them while the account menu below it had four.
            #
            # Each label is again exactly what it sends, and each is a phrasing
            # verified to route. The sentence's own general wording is not used
            # as a chip: it names a family rather than a question, so tapping it
            # would only reach the ladder above. Typed back by hand it is
            # recognised there (Dialogue::TopicMenu) and answered with the
            # option's own question instead of the menu it came from.
            def topic_menu_chips
              %w(report account service neighborhood).map do |choice|
                label = t("clarify_chip_#{choice}")
                { label:, send: label }
              end
            end

            # Managing an account the citizen already has starts from sign-in;
            # everything else starts from registration. Both are the real port,
            # so a verified account is never told to register.
            def account_handoff(facet)
              action = AccountQuestion::ACCOUNT_SURFACE.include?(facet) ? "sign_in" : "registration"
              result = @registration_port.call(action:, context:, locale: state.fetch("locale"))
              validate_handoff!(result)
              result
            end

            def account_answer(facet, result)
              key = AccountQuestion.information_key(facet)
              case facet
              when "already_registered"
                # Only the account's real state may say "you are already in".
                result.completed ? t(key, url: result.destination) : nil
              when "registration_award"
                values = registration_award_values
                values && t(key, **values, url: result.destination)
              else
                t(key, url: result.destination)
              end
            end

            # What registration is worth is NOT written into the copy: it is
            # read from the one schedule that actually awards it, so the
            # sentence cannot drift from the ledger. Unreadable schedule means
            # no number, never a guessed one.
            def registration_award_values
              verification = earning_points(:verification)
              area = earning_points(:komsiluk_selected)
              return unless verification&.positive? && area&.positive?

              { points: verification + area, verification:, area: }
            end

            def earning_points(name)
              points = Decidim::Bih::Goodwill::EarningRules.points_for_action(name)
              points.is_a?(Integer) ? points : nil
            rescue StandardError
              nil
            end

            # rubocop:disable Metrics/ParameterLists
            def finish(answer, resolution:, facts: [], offered: false, completed: false, prior_evidence: :retain, preserve_task: false, chips: [])
              constraint_key = { "read_only" => "read_only_question", "verified_transport" => "transport_verified_only" }[read_follow_up_kind]
              answer = "#{t(constraint_key)}\n\n#{answer}" if constraint_key
              # What a resolution label means for the task state is Resolution's.
              if Resolution.settles_task?(resolution) && !preserve_task
                state["pending_slot"] = nil unless Resolution.retains_pending_slot?(resolution, clarification_count: state["clarification_count"])
                state["clarification_count"] = 0 unless Resolution.retains_clarification_count?(resolution)
              end
              state["updated_at"] = context.now.to_f
              state["expires_at"] = context.now.to_f + Contracts::CONTEXT_TTL
              state["prior_evidence"] = prior_evidence == :retain ? carried_evidence : prior_evidence
              # Persist a level only when the citizen actually asked for one.
              # requested_level returns DEFAULT_LEVEL when nothing was asked, so
              # writing it unconditionally mutated state on every ordinary turn
              # - redundant churn in a CAS-versioned store, and exactly what the
              # late-provider contract test exists to catch. nil reads back as
              # the default, so the "kraće" ladder is unaffected.
              level = presentation_level
              state[StateStore::PRESENTATION_LEVEL_KEY] = (level unless level == FactRenderer::DEFAULT_LEVEL)
              state[AnswerContext::KEY] = answered_context(resolution, preserve_task:)
              # The offer to resume is made once per suspension, not on every
              # reply until the citizen takes it.
              if resumable_work_saved? && Resolution.offers_resume?(resolution) && !state["resume_offered"]
                answer += "\n\n#{t("resume_offer")}"
                state["resume_offered"] = true
              end
              if presentation_request? && %w(unsupported source_unavailable).include?(resolution)
                answer = fact_renderer.shorten(answer, level: presentation_level)
              end
              validated = StateStore.new.validate(context:, state:)
              Result.new(state: validated,
                         reply: Responder::Reply.new(text: answer, report: nil, answer_intent: answer_intent, quick_replies: chips),
                         resolution:, fact_ids: facts.freeze, handoff_offered: offered, handoff_completed: completed, diagnostics:)
            end
            # rubocop:enable Metrics/ParameterLists

            # A completed public lookup is remembered for an explicit return,
            # but is not unfinished work to announce beneath an unrelated answer.
            # A model-proposed secondary with no question or slots is not saved
            # citizen work either. Drafts and pending actionable tasks stay visible.
            def resumable_work_saved?
              saved = state["suspended_task"]
              return false unless saved
              return true if saved["draft"] || saved["pending_slot"]
              return false if saved["active_task"] == "ask_information"

              !saved.fetch("entities", {}).empty? || REGISTRATION_ACTIONS.include?(saved["active_task"])
            end

            # WHAT this turn answered, kept apart from the task it was answered
            # inside. Only a real ANSWER replaces it; a clarification, a
            # handoff or a refusal leaves the previous subject standing,
            # because the citizen has not moved off it. A turn that explicitly
            # preserves its task (an evidence follow-up) preserves this too.
            #
            # AnswerContext refuses everything it may not retain - a private
            # account, report or neighbourhood read, and a credential-shaped
            # question - by returning nil, which CLEARS the slot rather than
            # leaving a stale public subject behind a private answer.
            def answered_context(resolution, preserve_task:)
              retained = state[AnswerContext::KEY]
              return retained if preserve_task || resolution != Resolution::ANSWERED

              AnswerContext.capture(
                kind: "core_read", subject: "#{action}:#{topic}", action:, topic:, facet:,
                anchor: answer_anchor, now: context.now, state_expires_at: state.fetch("expires_at")
              )
            end

            # The citizen's own words for what was asked - the same rule the
            # reader itself is given (current_question_entities), so the anchor
            # is the question that was actually answered and never a rendered
            # fact from the reply.
            def answer_anchor
              query = current_question_entities["query"]
              query.is_a?(String) && query.match?(/\p{L}/) ? query : text
            rescue StandardError
              text
            end

            # rubocop:disable Metrics/CyclomaticComplexity
            def prior_evidence_follow_up(kind:)
              locale = evidence_locale
              state["locale"] = locale
              evidence = PriorEvidence.normalize(state["prior_evidence"], now: context.now, state_expires_at: state.fetch("expires_at"))
              return finish(t("prior_evidence_missing", locale:), resolution: "clarification", preserve_task: true) unless evidence

              evidence = refresh_member_evidence(evidence, locale:) if evidence.fetch("kind") == "member_board"
              return finish(t("prior_evidence_private_unavailable", locale:), resolution: "clarification", prior_evidence: nil, preserve_task: true) unless evidence

              answer = case kind
                       when "source" then evidence_source_reply(evidence, locale:)
                       when "date" then evidence_date_reply(evidence, locale:)
                       when "disagreement" then evidence_disagreement_reply(evidence, locale:)
                       else raise Contracts::Invalid, "Unknown evidence follow-up"
                       end
              answer += "\n\n#{t("stale", locale:)}" if evidence.fetch("status") == "stale"
              finish(answer, resolution: kind == "disagreement" ? "handoff" : "answered",
                             facts: evidence.fetch("facts").map { |fact| fact.fetch("id") },
                             offered: kind == "disagreement", prior_evidence: evidence, preserve_task: true)
            rescue Contracts::Invalid
              finish(t("prior_evidence_missing", locale: evidence_locale), resolution: "clarification", preserve_task: true)
            end
            # rubocop:enable Metrics/CyclomaticComplexity

            # Task 7's presentation operation, applied to an answer this runner
            # did not render itself (the legacy read adapter's).
            # The level is already resolved for this turn (presentation_level
            # stepped the saved one by what this message asked for), so it is
            # passed explicitly: letting the renderer step again would skip a
            # level every time.
            def shorten_reply(answer, level: nil)
              fact_renderer.shorten(answer.to_s, level: level || fact_renderer.level)
            rescue StandardError
              answer
            end

            # See ProcedureRunner#secondary_state. nil means "the transition was
            # refused; keep the saved state as it is".
            def secondary_state
              transition
              return nil if @transition_conflict

              clear_pending_slot
              state["updated_at"] = context.now.to_f
              state["expires_at"] = context.now.to_f + Contracts::CONTEXT_TTL
              state["prior_evidence"] = carried_evidence
              # Persist a level only when the citizen actually asked for one.
              # requested_level returns DEFAULT_LEVEL when nothing was asked, so
              # writing it unconditionally mutated state on every ordinary turn
              # - redundant churn in a CAS-versioned store, and exactly what the
              # late-provider contract test exists to catch. nil reads back as
              # the default, so the "kraće" ladder is unaffected.
              level = presentation_level
              state[StateStore::PRESENTATION_LEVEL_KEY] = (level unless level == FactRenderer::DEFAULT_LEVEL)
              state[AnswerContext::KEY] = AnswerContext.capture(
                kind: "legacy_read", subject: "#{action}:#{topic}", action:, topic:, facet:,
                anchor: answer_anchor, now: context.now, state_expires_at: state.fetch("expires_at")
              )
              StateStore.new.validate(context:, state:)
            rescue Contracts::Invalid
              nil
            end

            def transport_walking_follow_up
              return unless action == "ask_information" && topic == "transport"

              evidence = PriorEvidence.normalize(state["prior_evidence"], now: context.now, state_expires_at: state.fetch("expires_at"))
              stop_id = retained_walking_stop(evidence)
              return unless stop_id
              return if context.deadline&.expired?

              state["locale"] = text.match?(/\A(?:how|can|could|show|send|give|open)\b/i) ? "en" : evidence_locale
              count_read
              result = @read_port.transport_walking_directions(stop_id:, context:, locale: state.fetch("locale"))
              raise Contracts::Invalid, "Typed walking read required" unless result.is_a?(Contracts::ReadResult)
              return render_read(result) unless result.status == "ok"

              fact = validated_walking_fact(result, stop_id)
              finish(render_fact(fact), resolution: "answered", facts: [stop_id], prior_evidence: evidence, preserve_task: true)
            end

            def procedure_fee_follow_up
              return unless ProcedureQuestion.fee_follow_up?(text) && @read_port.respond_to?(:procedure_follow_up)

              procedure_id = ProcedureQuestion.retained_id(state:, context:)
              return unless procedure_id
              return if context.deadline&.expired?

              state["locale"] = text.match?(/\A(?:and|where|how|what)\b/i) ? "en" : evidence_locale
              count_read
              result = @read_port.procedure_follow_up(procedure_id:, focus: "fee", context:, locale: state.fetch("locale"))
              raise Contracts::Invalid, "Typed procedure read required" unless result.is_a?(Contracts::ReadResult)

              render_read(result)
            end

            def service_follow_up
              focus = ServiceFollowUpQuestion.focus(text)
              return unless focus && @read_port.respond_to?(:service_follow_up)

              source_id = ServiceFollowUpQuestion.retained_source_id(state:, context:)
              return unless source_id
              return if context.deadline&.expired?

              state["locale"] = text.match?(/\A(?:and|where|how|what)\b/i) ? "en" : evidence_locale
              count_read
              result = @read_port.service_follow_up(source_id:, focus:, context:, locale: state.fetch("locale"))
              raise Contracts::Invalid, "Typed service follow-up read required" unless result.is_a?(Contracts::ReadResult)

              render_read(result)
            end

            def public_information_follow_up
              return unless action == "ask_information" && !state["draft"] && context.allows?("public_reads")
              return if context.deadline&.expired? || state.dig("prior_evidence", "kind") == "member_board"

              locale = text.match?(/\A(?:and|where|how|what|does|is)\b/i) ? "en" : evidence_locale
              if UtilityScopeQuestion.match?(text, topic:)
                state["locale"] = locale
                return finish(t("utility_household_scope", locale:), resolution: "answered",
                                                                     prior_evidence: state["prior_evidence"], preserve_task: true)
              end
              return unless @read_port.respond_to?(:public_reference_follow_up)

              evidence = PriorEvidence.normalize(state["prior_evidence"], now: context.now, state_expires_at: state.fetch("expires_at"))
              return unless evidence && evidence.values_at("kind", "action", "topic", "status") == ["public_read", action, topic, "ok"]

              sources = evidence.fetch("facts").map { |fact| fact.fetch("source_id") }.uniq
              count_read
              result = @read_port.public_reference_follow_up(source_ids: sources, message: text, context:, locale:)
              return unless result
              raise Contracts::Invalid, "Typed public reference read required" unless result.is_a?(Contracts::ReadResult)

              state["locale"] = locale
              render_read(result)
            end

            private

            def text = message.respond_to?(:text) ? message.text.to_s.strip : message.to_s.strip

            attr_reader :understanding

            def count_read
              @read_count += 1
            end

            # The task transition this turn made: the understanding's operation
            # once it was applied, a resume or a cancel, else none (a guarded
            # reply, the empty-understanding fallback, a refused transition).
            def transition_token
              return "cancel" if @cancelled
              return "resume" if @resumed_task
              return "refused" if @transition_conflict
              return "none" unless @transitioned && understanding

              DIAGNOSTIC_TRANSITIONS.include?(understanding.operation) ? understanding.operation : "none"
            end

            # The host's reviewed next step for an unsupported topic (a URL or
            # a phone number), else the support destination.
            def unsupported_next_step
              candidate = @capabilities.respond_to?(:next_step_for) ? @capabilities.next_step_for(topic) : nil
              return candidate if candidate.is_a?(String) && (safe_url?(candidate) || candidate.match?(NEXT_STEP_PHONE))

              destination("support")
            end

            def normalize_literal_public_activity_place
              return unless understanding.action == "ask_information" && PublicActivityContinuation::TOPICS.include?(understanding.topic)
              return unless %w(start switch).include?(understanding.operation) && context.allows?("public_reads")
              return if state["draft"] || state.dig("prior_evidence", "kind") == "member_board" || location
              return if PublicActivityContinuation::PRIVATE_CONTEXT.match?(Text.fold(entities["query"]))
              return if %w(area_slug street address).any? { |key| !understanding.entities[key].to_s.strip.empty? }

              area = PublicActivityPlace.call(text:, supplied: understanding.entities["area_query"])
              return unless area

              # Persist the exact literal query through the ordinary validated
              # transition, so the next calendar follow-up keeps the same kind.
              # Query/category/time are deliberately not replaced by raw text.
              @understanding = Contracts::Understanding.parse(understanding.to_h.merge(entities: understanding.entities.merge("area_query" => area)))
            end

            # Host readers resolve citizen place/date phrases against their
            # own sources. Persist only the bounded public journey slots they
            # return, never identities, capabilities or arbitrary metadata.
            def retain_transport_query_entities(result, query: nil)
              return unless action == "ask_information" && topic == "transport"

              return unless %w(ok stale ambiguous empty unavailable unreviewed).include?(result.status) && result.coverage.is_a?(Hash)

              invalidate_transport_query_entities(result.coverage)
              # Keep the exact query the host identified as a calendar read,
              # even when the model supplied no query or a lossy paraphrase.
              # Only the reader's closed scope marker earns this persistence.
              if result.coverage["transport_query_scope"] == "calendar" && query.is_a?(String) &&
                 query.length.between?(1, 160) && !StateStore.sensitive_text?(query)
                entities["query"] = query
                state["entity_provenance"]["query"] = "citizen"
              end
              supplied = result.coverage["transport_query_entities"]
              return unless supplied.is_a?(Hash)

              supplied.slice("stop", "area_query", "via_stop", "transfer_mode", "date", "time_expression", "route").each do |key, value|
                retain_transport_slot(key, value)
              end
            end

            def invalidate_transport_query_entities(coverage)
              invalidated = coverage["transport_query_invalidated_entities"]
              return unless invalidated.is_a?(Array)

              # A source reader may reject an inferred origin or stale route.
              # It cannot erase dates, identity or arbitrary conversation state.
              allowed = %w(route stop via_stop transfer_mode)
              allowed << "area_query" if coverage["transport_query_scope"] == "calendar"
              remove_entities(*(invalidated & allowed))
            end

            def retain_transport_slot(key, value)
              return if %w(stop area_query via_stop).include?(key) && !TransportFollowUpQuestion.place_candidate?(value)
              return if key == "transfer_mode" && value != "direct"
              return unless value.is_a?(String) && value.length.between?(1, 160)
              return if StateStore.sensitive_text?(value)
              return if entities[key] == value && state["entity_provenance"][key]

              entities[key] = value
              state["entity_provenance"][key] = "citizen"
            end

            def retain_supplied_activity_area(result)
              return unless action == "ask_information" && %w(neighborhood participation community volunteer).include?(topic)
              return if %w(area_slug area_query street address).any? { |key| !entities[key].to_s.strip.empty? }
              return unless result.coverage.is_a?(Hash) && result.coverage["area_query_source"] == "citizen_activity_locative"

              area = result.coverage["supplied_area_query"]
              return unless area.is_a?(String) && area.length.between?(1, 160) && !StateStore.sensitive_text?(area)
              return unless Text.fold(text).include?(Text.fold(area)) || Text.fold(entities["query"]).include?(Text.fold(area))

              entities["area_query"] = area
              state["entity_provenance"]["area_query"] = "citizen"
            end

            def transport_no_feasible_answer(result)
              base = t("transport_no_feasible_journey")
              limits = result.validity
              keys = %w(maximum_transfers minimum_transfer_minutes maximum_transfer_wait_minutes)
              return base unless limits.is_a?(Hash) && keys.all? { |key| limits[key].is_a?(Integer) && limits[key].between?(0, 1440) }

              "#{base} #{t("transport_search_limits", **limits.slice(*keys).transform_keys(&:to_sym))}"
            end

            def clarify_transport_ambiguity(result)
              if result.warnings.include?("transport_calendar_date_required") && TransportFollowUpQuestion.calendar_follow_up_kind(text) == :date_needed
                return clarify("time_expression", "transport_calendar_date_needed")
              end
              return clarify("area_query", "ask_transport_destination") if result.warnings.include?("transport_destination_required")
              return clarify("stop", "ask_navigation_stop") if result.warnings.include?("transport_navigation_stop_required")
              if result.warnings.include?("transport_via_required")
                return clarify("via_stop", "transport_via_required", origin: entities["stop"].to_s,
                               destination: entities["area_query"].to_s, via: entities["via_stop"].to_s)
              end
              return clarify("query", "transport_shorten_question") if result.warnings.include?("transport_query_too_long")
              return clarify("time_expression", "transport_calendar_conflict") if result.warnings.include?("transport_calendar_date_conflict")
              return clarify("area_query", "transport_different_destination") if result.warnings.include?("transport_same_stop")
              return unless result.warnings.intersect?(%w(transport_origin_ambiguous transport_destination_ambiguous))

              choices = transport_stop_choices(result)
              if choices.any? && result.warnings.include?("transport_origin_ambiguous") && TransportFollowUpQuestion.service_kind_question?(text)
                return clarify("stop", "transport_service_kind_choose_stop", choices: choices.join("; "))
              end
              clarify(ambiguity_slot(result), "transport_choose_stop", choices: choices.join("; ")) unless choices.empty?
            end

            def transport_stop_choices(result)
              result.candidates.filter_map { |candidate| candidate["text"] if candidate.is_a?(Hash) }
                    .select { |name| name.is_a?(String) && name.length.between?(1, 160) }.uniq.first(5)
            end

            def clarify_read_ambiguity(result)
              if topic == "transport" && (clarification = clarify_transport_ambiguity(result))
                return clarification
              end

              slot = ambiguity_slot(result)
              if slot == "area_query" && entities["area_query"] &&
                 (choices = Procedures::Komsiluk.choices_text(result.candidates, locale: state.fetch("locale")))
                return clarify(slot, "supplied_area_choice", area: entities.fetch("area_query"), choices:)
              end

              if slot == "area_query" && entities["area_query"] && result.candidates.empty?
                return clarify(slot, "supplied_area_unresolved", area: entities.fetch("area_query"))
              end
              clarify(slot, "ask_#{slot}")
            end

            def retained_walking_stop(evidence)
              return unless evidence && evidence.values_at("kind", "action", "topic", "status") == %w(public_read ask_information transport ok)

              stops = evidence.fetch("facts").select do |fact|
                fact["source_id"] == "public_transport_stop_registry" && fact.fetch("id").match?(/\Atransport_stop:[a-f0-9]{12}\z/)
              end
              stops.first.fetch("id") if stops.one? && @read_port.respond_to?(:transport_walking_directions)
            end

            def validated_walking_fact(result, stop_id)
              facts = validated_facts(result)
              unless facts.one? && facts.first.values_at("id", "source_id") == [stop_id, "public_transport_stop_registry"]
                raise Contracts::Invalid, "Walking read must match the retained public stop"
              end

              facts.first
            end

            def normalize_neighborhood_continuation
              return if normalize_public_activity_continuation
              return unless topic == "neighborhood" && %w(ask_information neighborhood_information).include?(action)
              return if state["draft"] || resume_requested?

              slots = neighborhood_continuation_slots
              return unless slots

              # Closed public choices and a requested place are continuations,
              # not extra tasks. Still use normal entity/transition validation.
              @understanding = Contracts::Understanding.parse(action:, topic:, entities: slots, operation: "continue",
                                                              needs_clarification: false, secondary: nil, locale: understanding.locale)
            end

            def normalize_public_activity_continuation
              @public_activity_refinement = !PublicActivityContinuation.call(text:, state:, locale: understanding.locale).nil?
              input = ProcedureRunner.public_activity_continuation_input(text:, state:, locale: understanding.locale)
              return false unless input

              # A closed change of public activity family keeps the citizen's
              # place/calendar, not a new task or board authority. In particular
              # "uskoro" reaches the owning volunteer calendar intact; that
              # reader decides its window, not a model-suggested task switch.
              @public_activity_continuation = input.topic == "volunteer"
              @understanding = input
              true
            end

            def public_activity_follow_up?
              !ProcedureRunner.public_activity_continuation_input(text:, state:, locale: understanding.locale).nil?
            end

            def neighborhood_continuation_slots
              if (state["pending_slot"] == "query" || action == "ask_information") && Procedures::Komsiluk.public_choice?(text)
                { "query" => text }
              elsif action == "ask_information" && state["pending_slot"] == "area_query" && generic_neighborhood_understanding?
                area = Procedures::Komsiluk.area_answer(text)
                { "area_query" => understanding.entities["area_query"] || area } if area
              end
            end

            def generic_neighborhood_understanding?
              return false if understanding.action == action && understanding.topic == topic &&
                              %w(continue correct).include?(understanding.operation) && !understanding.needs_clarification &&
                              !understanding.entities["area_query"].to_s.empty?
              return understanding.topic == "neighborhood" if understanding.action == "choose_area"

              %w(help ask_information neighborhood_information).include?(understanding.action) &&
                %w(unknown neighborhood city_service).include?(understanding.topic)
            end

            def guarded_reply
              return registration_information if account_correction?
              return cancel if cancellation?
              return confirm_cancel if asserted_cancel?
              return finish(t("credentials"), resolution: "unsupported") if StateStore.sensitive_text?(text)

              safety_reply if understanding.action == "safety"
            end

            # "Ne registracija, nego odjava postojećeg naloga" is a CORRECTION
            # of which account journey we are on, not a request to abandon the
            # conversation — and it was answered "U redu, odustali smo od ovog
            # zadatka". A contrast marker plus a journey named in the citizen's
            # OWN words is enough to answer the journey they named instead.
            #
            # Deliberately narrow: only a model-asserted cancel, only inside the
            # account family, and only when the text itself resolves to a facet.
            # An explicit clear command still clears.
            def account_correction?
              return false unless understanding.action == "cancel" || understanding.operation == "cancel"
              return false if StateStore.clear_command?(text)
              return false unless account_family? && Text.fold(text).match?(ACCOUNT_CORRECTION)

              !AccountQuestion.facet(text).nil?
            end

            # A cancel destroys the citizen's slots, so a model-asserted one
            # needs deterministic corroboration whenever there is something to
            # lose. "Dobro, hvala." reaching the model and coming back as
            # "cancel" is how a whole task used to disappear.
            def cancellation?
              return true if StateStore.clear_command?(text)
              return false unless understanding.action == "cancel" || understanding.operation == "cancel"
              return true unless destructive_cancel?

              (message.respond_to?(:cancel?) && message.cancel? == true) || ProcedureRunner.cancellation_wording?(text)
            end

            # Reached only when #cancellation? refused a model-asserted cancel:
            # it would have destroyed the citizen's work and no deterministic
            # predicate corroborated it. Ask instead of executing — and name the
            # exact word that does cancel, so the question cannot loop.
            def asserted_cancel?
              understanding.action == "cancel" || understanding.operation == "cancel"
            end

            def confirm_cancel
              clarify(state["pending_slot"] || "query", "cancel_confirm", charge: false)
            end

            # True when a cancel would throw away work the citizen did: an
            # opaque draft, an offered report, or slots they supplied themselves.
            def destructive_cancel?
              return false unless action

              return true if state["draft"] || state["report_handoff_offered"] || state["suspended_task"]

              state.fetch("entity_provenance").any? { |_, source| %w(citizen corrected).include?(source) }
            end

            # A refused transition is OUR refusal, not the citizen's mistake:
            # it is named in the diagnostics ("refused", previously
            # indistinguishable from two other cases) and does not spend the
            # clarification budget.
            def post_transition_reply
              clarify(state["pending_slot"] || "query", "clarify", charge: false, chips: topic_menu_chips) if @transition_conflict
            end

            def unresolved_understanding_reply
              return unless understanding == Contracts::Understanding.clarify(locale: understanding.locale)
              return if resume_requested?

              # An empty understanding fallback is not a request to rerun the
              # previous procedure. Keep its task and valid slots, and repeat
              # the pending question when one exists. Explicit suspended-task
              # resume deliberately uses this same tuple and remains separate.
              state["locale"] = understanding.locale if text.match?(/\p{L}/) || !action
              slot = state["pending_slot"] || "query"
              specific = state["pending_slot"] && %w(query description area_query time_expression stop reference).include?(slot)
              return clarify(slot, "ask_#{slot}") if specific

              topic_clarification(slot)
            end

            def safety_reply
              preserved = StateStore.new.validate(context:, state:)
              Result.new(
                state: preserved,
                reply: Responder::Reply.new(text: t("safety", locale: understanding.locale), report: nil, answer_intent: "safety"),
                resolution: Resolution::SAFETY_GUIDANCE, fact_ids: [].freeze, handoff_offered: false, handoff_completed: false, diagnostics:
              )
            end

            def conceptual_transport_reply
              return unless action == "ask_information" && topic == "transport" && !state["draft"]

              request = TransportQuestionRoute.conceptual_request(text, state: state.merge("entities" => @entry_entities))
              return unless request

              finish(t(request.fetch(:key), **request.fetch(:values)), resolution: "answered", preserve_task: true)
            end

            def read_follow_up_kind
              TextPredicates.read_follow_up_kind(text, state)
            end

            def requested_missing_detail
              return unless %w(read_only missing_detail).include?(read_follow_up_kind)

              slot = state["pending_slot"]
              slot ||= "area_query" if %w(waste water electricity heating roads).include?(topic) && !has_location?
              return unless %w(area_query stop time_expression).include?(slot)

              clarify(slot, "ask_#{slot}")
            end

            def repair_reply
              return unless understanding.operation == "correct" && understanding.needs_clarification

              return if action == "ask_information" && !state["draft"] &&
                        (@supplied_entity_keys - %w(query)).any?

              # A typed repair is a request to resolve the misunderstanding, not
              # permission to replay the completed procedure.  Transition first
              # so valid supplied slots and the active/suspended task survive;
              # then discard any stale opaque draft before asking one bounded
              # distinguishing question.
              @draft_replaced = !state["draft"].nil?
              state["draft"] = nil
              clarify("query", "repair_clarify", restart: true)
            end

            def cancel
              version, created = state.values_at("version", "created_at")
              @state = StateStore.new.empty_state(context).merge("version" => version, "created_at" => created, "locale" => state["locale"])
              @cancelled = true
              finish(t("cancelled"), resolution: "cancelled")
            end

            def transition
              return resume_suspended_task if resume_requested?

              input = destination_refinement_input(same_day_transport_continuation(elliptical_continuation(understanding)))
              previous = state.slice(*StateStore::TASK_KEYS)
              target = target_action(input)
              return mark_transition_conflict if invalid_transition?(input, target)

              prepare_target_task(previous, input, target)
              update_task_identity(input, target, previous)
              apply_entities(input)
              install_secondary(input.secondary)
              @transitioned = true
            end

            # An entity-free question that refers back to the answer just given
            # is a refinement of the task in hand. The model cannot see that
            # from the words alone and proposes a switch; the switch then resets
            # the entity bag and the RETAINED question is answered instead of
            # the one the citizen just asked.
            def destination_refinement_input(input)
              @destination_refinement = TransportFollowUpQuestion.destination_refinement?(text, state:)
              facet_refinement = action == "ask_information" && topic == "transport" && !state["draft"] &&
                                 (TransportFollowUpQuestion.facet_follow_up?(text) || TransportQuestionRoute.conceptual_request(text, state:))
              return input unless @destination_refinement || facet_refinement

              @understanding = Contracts::Understanding.parse(input.to_h.merge(
                action: "ask_information", topic: "transport", operation: "continue", needs_clarification: false, secondary: nil
              ))
            end

            def elliptical_continuation(input)
              return input unless action && input.operation == "switch"
              return input unless input.entities.reject { |_, value| value.strip.empty? }.empty?
              return input unless TextPredicates.back_reference?(Text.fold(text))

              @understanding = Contracts::Understanding.parse(input.to_h.merge(action:, topic:, operation: "continue"))
            end

            # An explicit citizen reference to the selected day is a continuation
            # even if the model calls the return journey a new task. Other starts
            # still reset their context; a model-only same-day claim has no power.
            def same_day_transport_continuation(input)
              return input unless transport_day_reference_context?(input)
              return input if transport_calendar_change?

              @transport_task_return = active_transport_return?
              return input unless @transport_task_return || Text.fold(text).match?(/\b(?:istog dana|isti dan|tog dana|same day)\b/)

              @same_day_transport_reference = true
              return input unless %w(start switch).include?(input.operation)

              @understanding = Contracts::Understanding.parse(input.to_h.merge(operation: "continue"))
            end

            def transport_day_reference_context?(input)
              action == "ask_information" && topic == "transport" && entities["date"] && !state["draft"] &&
                input.action == action && input.topic == topic
            end

            # Public guidance can answer a detour without suspending the task.
            # Returning to that still-active journey keeps its reviewed day. A
            # model start, date or clock cannot substitute for the citizen's
            # words; the host reader still parses explicit new clock/endpoints.
            def active_transport_return?
              return false unless text.length <= 1000

              folded = Text.fold(text)
              return false if folded.match?(/\b(?:ne|nemoj|nov\w*|drug\w*|prijav\w*|parking|not|no|new|another)\b/)

              folded.match?(/\A(?:(?:hajde|ajde|molim[ ]te|a)[ ])?
                (?:(?:vratimo[ ]se|vrati[ ]se|nazad)(?:[ ]na)?|(?:go[ ])?back[ ]to(?:[ ]the)?|return[ ]to(?:[ ]the)?)
                [ ](?:autobus\w*|prevoz\w*|prijevoz\w*|bus|transport)\b/x)
            end

            # Without this, the retained numeric clock outranks literal "noon"
            # in a reader's time parser. Only citizen text clears that old slot.
            def transport_return_time_change?
              text.match?(/\b(?:[01]?\d|2[0-3]):[0-5]\d\b/) ||
                Text.fold(text).match?(/\b(?:ujutru|ujutro|rano|prijepodne|prepodne|morning|popodne|poslijepodne|poslepodne|afternoon|vecer|evening|podne|noon)\b/)
            end

            def resume_requested?
              ProcedureRunner.resume_request?(text, state)
            end

            def resume_suspended_task
              restored = state.fetch("suspended_task")
              @state = state.merge(restored).merge("entities" => restored.fetch("entities").dup,
                                                   "entity_provenance" => restored.fetch("entity_provenance").dup,
                                                   "suspended_task" => nil, "resume_offered" => false)
              @resumed_task = true
              carry_resume_question
            end

            # A return request may bring its own question ("…, koji dan si
            # rekla?"). The restored task keeps its slots; only the question
            # this turn actually asks replaces the one it was suspended on.
            def carry_resume_question
              carried = TextPredicates.resume_request_tail(text)
              return unless carried && !StateStore.sensitive_text?(carried)

              entities["query"] = carried[0, 160]
              state["entity_provenance"]["query"] = "citizen"
              @supplied_entity_keys |= ["query"]
            end

            def invalid_transition?(input, target)
              return secondary_overflow?(input.secondary) if state["active_task"].nil?
              return true if controlled_operation_conflict?(input)

              return true if %w(start switch).include?(input.operation) && task_differs?(target, input.topic) && state["suspended_task"] && !replaceable_active_task?

              secondary_overflow?(input.secondary)
            end

            def replaceable_active_task?
              return false if state["draft"]
              return true if action == "report_problem" && state.fetch("report_handoff_offered")
              return true if unfinished_report_can_replace_completed_read?

              REGISTRATION_ACTIONS.include?(action) || %w(ask_information report_status neighborhood_information choose_area).include?(action)
            end

            def unfinished_report_can_replace_completed_read?
              return false unless action == "report_problem" && !state["draft"] && !state["report_handoff_offered"]

              saved = state["suspended_task"]
              saved && saved["active_task"] == "ask_information" && saved["pending_slot"].nil? && saved["draft"].nil?
            end

            def target_action(input)
              return action if input.needs_clarification && input.action == "help" && action
              return action if account_information_continuation?(input)

              input.action
            end

            def controlled_operation_conflict?(input)
              return false unless %w(continue correct clarify).include?(input.operation)
              return false if account_information_continuation?(input)
              return true if input.action != action && !(input.needs_clarification && input.action == "help")
              # Describing a generic pending report establishes its civic topic;
              # it does not switch away from the report or correct a known fault.
              return false if pending_report_description?(input)
              return false if compatible_continuation_topic?(input)

              input.operation != "correct"
            end

            def pending_report_description?(input)
              action == "report_problem" && topic == "report" && state["pending_slot"] == "description" &&
                entities["description"].to_s.empty? && !input.entities["description"].to_s.empty?
            end

            def compatible_continuation_topic?(input)
              return true if @public_activity_continuation && input.action == "ask_information" && input.topic == "volunteer"

              input.topic == "unknown" || topic == "unknown" || input.topic == topic
            end

            def account_information_continuation?(input)
              %w(continue clarify).include?(input.operation) && (REGISTRATION_ACTIONS.include?(action) || registration_area_selection?) &&
                topic == "account" && input.action == "ask_information" && input.topic == "account"
            end

            def secondary_overflow?(secondary)
              return false unless secondary && state["suspended_task"]
              return false unless resumable_secondary?(secondary)

              suspended = state.fetch("suspended_task")
              secondary.fetch("action") != suspended.fetch("active_task") || secondary.fetch("topic") != suspended.fetch("topic")
            end

            def prepare_target_task(previous, input, target)
              if %w(start switch).include?(input.operation) && task_differs?(target, input.topic) && unfinished_report_can_replace_completed_read?
                # Keep the unfinished report, not an already answered detour.
                # There is still only one suspended task and no draft is lost.
                @state = state.merge("suspended_task" => nil)
                return reset_task(previous, suspend: true, target:)
              end
              return reset_task(previous, suspend: false, target:) if input.operation == "start" && previous["active_task"]
              return unless input.operation == "switch" && task_differs?(target, input.topic)

              # With one task already saved, replace only the safe active task.
              # Never overwrite that suspension or grow a third task slot.
              reset_task(previous, suspend: state["suspended_task"].nil?, target:)
            end

            def reset_task(previous, suspend:, target:)
              fresh_task = StateStore.new.empty_state(context).slice(*StateStore::TASK_KEYS)
              # A real task change drops the retained answer with the task it
              # belonged to: a continuation must never reach across a switch.
              @state = state.merge(fresh_task).merge("locale" => previous.fetch("locale"), AnswerContext::KEY => nil)
              if suspend && resumable_task?(previous["active_task"])
                state["suspended_task"] = previous
                state["resume_offered"] = false
              end
              # A report detour about the current neighborhood keeps its area,
              # not board membership, private facts or a previous report body.
              inherit_location(previous) if suspend && target == "report_problem" && NEIGHBORHOOD_ACTIONS.include?(previous["active_task"])
            end

            def resumable_task?(task)
              return false if task.nil? || CONTROL_ACTIONS.include?(task)

              true
            end

            def task_differs?(target, requested_topic)
              target != action || (requested_topic != "unknown" && requested_topic != topic)
            end

            def update_task_identity(input, target, previous)
              state["active_task"] = target
              state["topic"] = input.topic unless input.topic == "unknown" && state["topic"] != "unknown"
              state["locale"] = input.locale if text.match?(/\p{L}/) || !previous["active_task"]
            end

            def mark_transition_conflict
              @transition_conflict = true
            end

            def inherit_location(previous)
              %w(area_query area_slug street address).each do |key|
                next unless previous.fetch("entities").has_key?(key)

                entities[key] = previous.fetch("entities").fetch(key)
                state["entity_provenance"][key] = previous.fetch("entity_provenance").fetch(key, "citizen")
              end
            end

            def apply_entities(input)
              # Travel constraints are derived from the literal question by
              # the host parser, never accepted from model-invented flags.
              candidates = input.entities.reject { |key, value| %w(transfer_mode via_stop).include?(key) || value.strip.empty? }
              if candidates["category"] == "stop_navigation" && !TransportQuestionRoute.navigation_instruction?(text)
                candidates = candidates.except("category")
              end
              if entities["category"] == "stop_navigation" && TransportQuestionRoute.journey_switch?(text)
                remove_entities("category")
              end
              raise Contracts::Invalid, "Credential in candidate entities" if candidates.values.any? { |value| StateStore.sensitive_text?(value) }

              # The citizen explicitly kept the selected day. A model-supplied
              # replacement date cannot overrule that reference.
              candidates = candidates.except("date") if @same_day_transport_reference
              # A literal return without a new calendar retains its window;
              # current clock changes reach the parser in the raw question.
              candidates = transport_return_candidates(candidates)
              if action == "ask_information" && topic == "transport"
                candidates = candidates.reject do |key, value|
                  %w(stop area_query).include?(key) &&
                    (TransportFollowUpQuestion.facet_follow_up?(text) || !TransportFollowUpQuestion.place_candidate?(value) ||
                     ungrounded_pending_transport_endpoint?(key, value))
                end
              end
              if @destination_refinement
                candidates = candidates.except("stop")
              end
              canonical_candidates_to_citizen_queries(candidates)
              candidates = candidates.except(*ungrounded_place_keys(candidates))
              echoes = candidates.select { |key, value| echoed_entity?(key, value) }
              candidates = candidates.except(*echoes.keys)
              @supplied_entity_keys = candidates.keys
              invalidate_dependent_entities(candidates, correction: input.operation == "correct", operation: input.operation)
              replace_draft(candidates, correction: input.operation == "correct")
              entities.merge!(candidates)
              candidates.each_key { |key| state["entity_provenance"][key] = input.operation == "correct" ? "corrected" : "citizen" }
              clear_satisfied_pending_slot(candidates)
            end

            # A timetable candidate is not a citizen choice. While either
            # endpoint remains unresolved, a model may retain already supplied
            # identity tokens but cannot add CSP/centre/school from the offered
            # alternatives unless the citizen actually names that qualifier.
            # Aliases still reach the host in the literal query for resolution.
            def ungrounded_pending_transport_endpoint?(key, value)
              return false unless %w(stop area_query).include?(@entry_pending_slot)

              known = PlaceGrounding.tokens(@entry_entities[key].to_s)
              spoken = PlaceGrounding.tokens(text)
              PlaceGrounding.identifying_tokens(value).any? do |token|
                !(known + spoken).any? { |witness| PlaceGrounding.witnessed?(token, witness) }
              end
            end

            def transport_return_candidates(candidates)
              return candidates unless @transport_task_return

              remove_entities("time_expression") if transport_return_time_change?
              candidates.except("time_expression")
            end

            # A place slot that is half the citizen's words and half words they
            # never wrote is a mangled quotation, not a fact. "pa u bijelini
            # brate, dsnica" (a mistyped Dašnica) came back as "Bijelina,
            # Dvorovi" and was answered with Dvorovi's collection days — a
            # confident answer about a different settlement. Refusing the
            # candidate whole leaves the slot empty, which is what the
            # procedures already know how to handle: they ask
            # (`ask_area_query`). Trimming it to its grounded half would answer
            # a question the citizen did not ask. A retained value survives — a
            # mangled quotation must not overwrite a place we already trusted.
            def ungrounded_place_keys(candidates)
              keys = candidates.select do |key, value|
                PlaceGrounding::SLOTS.include?(key) && PlaceGrounding.mangled?(value, text, *retained_place_values)
              end.keys
              @dropped_entity_keys.concat(keys)
              keys
            end

            # The conversation's own place slots witness a refinement: answering
            # "komšiluk Janja ili MZ Janja?" with "mjesna zajednica" must still
            # be allowed to carry Janja, which this turn's words do not repeat.
            def retained_place_values
              PlaceGrounding::SLOTS.map { |key| entities[key].to_s }
            end

            # The model is shown the retained entity VALUES, including a
            # suspended task's, so it can hand back a street the citizen never
            # repeated — and it would then be stamped "citizen", after which
            # nothing downstream can tell a supplied slot from a retained one.
            # A candidate that equals what is already stored and does not appear
            # in this turn's own words is that echo.
            #
            # == A TURN THAT NAMES ITS OWN SUBJECT OR LOCATION INHERITS NEITHER
            #
            # That is the precedence rule, and the fence above could not keep
            # it. A real topic switch RESETS the entity bag before the
            # candidates are merged, so by the time an echo is looked for there
            # is nothing stored to compare against and the echo is admitted as
            # if the citizen had just said it. Live, 14.09.2026: a waste
            # question about Ulica Filipa Višnjića, and three turns later "broj
            # za SMS parking u plavoj zoni" answered with the WHITE zone —
            # 083 5500 at 1,50 KM/h instead of the blue zone's 083 5502 at
            # 0,60 KM/h. The citizen named their own zone and was handed the
            # previous subject's street.
            #
            # So a value that was in the bag when this TURN STARTED, is gone
            # from it now (the switch), and does not appear in the citizen's
            # own words is an echo too. There is no "zone" slot — a zone is
            # named in the question itself — which is exactly why the stale
            # street was able to outrank it downstream.
            def echoed_entity?(key, value)
              return false unless LITERAL_ENTITY_KEYS.include?(key)
              return true if retained_across_switch?(key, value)
              return false unless entities[key].to_s == value

              # Not String#exclude?: these unit tests load the engine without
              # ActiveSupport's core extensions, exactly as FactRenderer does.
              !Text.fold(text).include?(Text.fold(value)) # rubocop:disable Rails/NegateInclude
            end

            # The switch case only. A turn that did not switch still has its
            # value in +entities+ and is decided by the rule above, unchanged.
            def retained_across_switch?(key, value)
              return false unless CARRIED_LOCATION_KEYS.include?(key)
              return false if entities[key].to_s == value
              return false unless @entry_entities[key].to_s == value

              !said_this_turn?(value)
            end

            # Did the citizen's CURRENT words carry this value? Serbian
            # declines a place name — "u Nušićevoj" still says "Nušićeva" — so
            # a literal containment test would call a repeated street an echo
            # and drop a location the citizen did name. The stem of the value's
            # longest word decides; a coincidental stem match only keeps the
            # value, which is the conservative direction.
            def said_this_turn?(value)
              folded = Text.fold(value)
              return false if folded.empty?

              spoken = Text.fold(text)
              return true if spoken.include?(folded)

              longest = folded.split.max_by(&:length).to_s
              longest.length > STEM_TAIL + 2 && spoken.include?(longest[0..-(STEM_TAIL + 1)])
            end

            # An opaque draft is destroyed only by a correction or by a slot the
            # draft actually depends on. A confirmation the model decorates with
            # an unrelated entity used to mint a new reference, so the
            # "Potvrdi slanje <ref>" chip the citizen was looking at went stale.
            def replace_draft(candidates, correction:)
              relevant = candidates.any? { |key, value| DRAFT_SLOTS.include?(key) && entities[key].to_s != value }
              return unless correction || relevant

              @draft_replaced = !state["draft"].nil?
              state["draft"] = nil
              state["report_handoff_offered"] = false
            end

            def invalidate_dependent_entities(candidates, correction:, operation:)
              invalidate_location_entities(candidates, correction:)
              if candidates.has_key?("time_expression") && !@same_day_transport_reference && !transport_clock_refinement?(candidates.fetch("time_expression"), operation:)
                remove_entities("date")
              end
              remove_entities("time_expression") if candidates.has_key?("date")
            end

            # A clock refines the selected travel day. Calendar expressions still
            # replace it, and model-proposed prose is never sufficient to keep it.
            def transport_clock_refinement?(expression, operation:)
              return false unless action == "ask_information" && topic == "transport" && %w(continue correct clarify).include?(operation)

              clock = /\A(?:(?:istog\ dana|isti\ dan|tog\ dana|same\ day)\s+)?
                (?:(?:u|at|after|poslije|posle|nakon|od|oko|around)\s+)?(?:[01]?\d|2[0-3])(?:\s[0-5]\d)?
                (?:\s*h|\s+(?:sati|ujutro|ujutru|morning))?
                (?:\s+(?:istog\ dana|isti\ dan|tog\ dana|same\ day))?\z/ix
              return false unless Text.fold(expression.to_s).match?(clock)

              !transport_calendar_change?
            end

            def transport_calendar_change?
              return true if text.match?(%r{\b\d{4}-\d{1,2}-\d{1,2}\b|\b\d{1,2}[./-]\d{1,2}\b})

              normalized = Text.fold(text)
              normalized.match?(/\b(?:danas|sutra|preksutra|juce|jucer|jutros|veceras|today|tomorrow|yesterday|tonight|
                poned\w*|utor\w*|srijed\w*|sred\w*|cetvrt\w*|petak|petkom|subot\w*|nedjelj\w*|nedelj\w*|
                monday|tuesday|wednesday|thursday|friday|saturday|sunday|prazni\w*|raspust\w*|holiday|vacation|break|
                januar\w*|februar\w*|mart\w*|april\w*|maj\w*|jun\w*|jul\w*|avgust\w*|septemb\w*|oktob\w*|novemb\w*|decemb\w*|
                march|may|august|october|sijecn\w*|veljac\w*|ozuj\w*|trav\w*|svib\w*|lip\w*|srpanj\w*|srpnj\w*|kolov\w*|rujan\w*|rujn\w*|listop\w*|studen\w*|prosin\w*)\b|
                \b(?:sljedec\w*|sledec\w*|naredn\w*|drug\w*|previous|next)\s+(?:dan\w*|day)\b|\bza\s+\d+\s+dana\b/x)
            end

            def invalidate_location_entities(candidates, correction:)
              remove_entities("area_slug") if %w(area_query street address).any? { |key| candidates.has_key?(key) }
              return unless correction

              if candidates.has_key?("area_query")
                remove_entities("street", "address")
              else
                invalidate_corrected_street(candidates)
              end
            end

            # The area matcher reads area_slug/area_query and NOTHING else, so a
            # retained area silently outranked every corrected street: the
            # citizen said "Baje Pivljanina" and kept getting MZ Centar. A
            # REPORT is different — its location is composed from every slot the
            # citizen gave, and the street refines the area rather than
            # replacing it.
            def invalidate_corrected_street(candidates)
              remove_entities("address") if candidates.has_key?("street")
              remove_entities("street") if candidates.has_key?("address")
              return if action == "report_problem"

              remove_entities("area_query") if %w(street address).any? { |key| candidates.has_key?(key) }
            end

            def remove_entities(*keys)
              keys.each do |key|
                next unless entities.has_key?(key) || state["entity_provenance"].has_key?(key)

                @dropped_entity_keys << key
                entities.delete(key)
                state["entity_provenance"].delete(key)
              end
            end

            def clear_satisfied_pending_slot(candidates)
              # Account questions are resolved by the supported explanation,
              # not merely by the presence of another unrecognized query.
              return if registration_information_request? && state["pending_slot"] == "query"
              # A supplied area/date/reference can still be ambiguous. Let
              # the read result resolve it before resetting the retry budget.
              return unless procedure == Procedures::Registration || action == "report_problem"
              return unless candidates.has_key?(state["pending_slot"])

              clear_pending_slot
            end

            def clear_pending_slot
              state["pending_slot"] = nil
              state["clarification_count"] = 0
            end

            def install_secondary(secondary)
              return unless resumable_secondary?(secondary)
              return if state["suspended_task"]

              state["suspended_task"] = StateStore.new.empty_state(context).slice(*StateStore::TASK_KEYS).merge(
                "active_task" => secondary.fetch("action"), "topic" => secondary.fetch("topic"), "locale" => state.fetch("locale")
              )
              state["resume_offered"] = false
            end

            def resumable_secondary?(secondary)
              return false unless secondary
              return false if CONTROL_ACTIONS.include?(secondary.fetch("action"))

              secondary.fetch("action") != action || secondary.fetch("topic") != topic
            end

            def procedure
              return Procedures::ReportProblem if %w(report_problem report_status).include?(action)
              return Procedures::Registration if REGISTRATION_ACTIONS.include?(action) || registration_area_selection? || registration_information_request?
              return Procedures::Komsiluk if NEIGHBORHOOD_ACTIONS.include?(action) || topic == "neighborhood"

              Procedures::CityService
            end

            def validated_facts(result)
              seen = {}
              result.facts.first(8).map do |original|
                fact = validated_fact(original, result)
                identifier = fact.fetch("id")
                raise Contracts::Invalid, "Duplicate fact identifier" if seen[identifier]

                seen[identifier] = true
                fact
              end
            end

            def validated_fact(original, result)
              raise Contracts::Invalid, "Fact envelope required" unless original.is_a?(Hash)

              fact = original.dup
              validate_fact_fields!(fact)
              project_fact_evidence!(fact)
              apply_result_source!(fact, single_source(result))
              stable_identifier!(fact["source_id"], "Fact provenance")
              fact
            end

            def project_fact_evidence!(fact)
              validity = fact["validity"].is_a?(Hash) ? fact["validity"] : {}
              fact["service_day"] ||= validity["date"] if validity["precision"] == "day"
              project_fact_validity!(fact, validity)
              fact["source_published_at"] ||= fact["source_published_on"]
              %w(service_day starts_at ends_at valid_until reviewed_on source_published_at source_updated_at).each do |key|
                next if fact[key].nil?

                fact[key] = PriorEvidence.applicability_date!(fact[key], key)
              end
            end

            def project_fact_validity!(fact, validity)
              fact["starts_at"] ||= validity["starts_at"] || validity["opens_on"]
              fact["ends_at"] ||= validity["ends_at"] || validity["closes_on"]
              fact["valid_until"] ||= fact["signup_deadline_at"] || validity["valid_until"]
            end

            def validate_fact_fields!(fact)
              stable_identifier!(fact["id"], "Fact identifier")
              stable_identifier!(fact["kind"], "Fact kind")
              Contracts.text!(fact["text"], limit: 1000)
              raise Contracts::Invalid, "Empty fact text" if fact["text"].strip.empty?
            end

            def stable_identifier!(value, label)
              Contracts.text!(value, limit: 160)
              raise Contracts::Invalid, "#{label} required" unless value.match?(STABLE_IDENTIFIER)
            end

            def apply_result_source!(fact, source)
              fact["source_id"] ||= source["id"]
              fact["source_label"] ||= source["label"]
              fact["source_url"] ||= source["url"]
            end

            def canonical_candidates_to_citizen_queries(candidates)
              slug = candidates.delete("area_slug")
              area_text = literal_text(slug)
              candidates["area_query"] ||= area_text if area_text
              date = candidates["date"]
              return unless date

              candidates.delete("date") unless valid_literal_date?(date) && !candidates.has_key?("time_expression")
            rescue Date::Error
              candidates.delete("date")
            end

            def literal_text(candidate)
              return unless candidate

              match = text.match(/#{Regexp.escape(candidate)}/i)
              match&.[](0)
            end

            def valid_literal_date?(date)
              text.include?(date) && date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(date).iso8601 == date
            end

            # Fact, source, freshness and grouping composition lives in
            # FactRenderer (Task 7 owns it). These delegators keep the call
            # sites outside that composition unchanged.
            def fact_renderer = @fact_renderer ||= FactRenderer.new(self, level: presentation_level)

            # The brevity level in force for THIS turn: the saved level stepped
            # by whatever this message asks for. Task 7 owns the rendering; this
            # owns which level it renders at, and remembers it so a second
            # "kraće" is shorter than the first instead of identical to it.
            def presentation_level
              @presentation_level ||= FactRenderer.requested_level(text, current: state[StateStore::PRESENTATION_LEVEL_KEY])
            end

            # A bare "kraće" / "detaljnije": a presentation operation on the
            # answer already given. Never a new task, never a cancellation, and
            # never a new question — the retained query stands.
            def presentation_request?
              return @presentation_request if defined?(@presentation_request)

              @presentation_request = !!(action && TextPredicates.presentation_request?(Text.fold(text)))
            end

            # Retained evidence belongs to the task it was captured for. It now
            # survives a turn that asked a question instead of answering one — a
            # clarification, a handoff, a control reply — which used to erase it
            # and break every supported follow-up after it.
            #
            # It is dropped as soon as any of three things is true: the task or
            # topic it describes is no longer the current one; the turn was a
            # cancellation; or THIS TURN RE-READ THE SOURCE. The last one is the
            # safety rule — a fresh unavailable, unreviewed or empty read has
            # re-checked the source and failed, and the old answer must not
            # outlive it.
            def carried_evidence
              evidence = state["prior_evidence"]
              return nil unless evidence.is_a?(Hash)
              return nil if @cancelled || @read_count.positive?
              return nil unless evidence["action"] == action && evidence["topic"] == topic

              evidence
            end

            def render_fact(fact) = fact_renderer.render_fact(fact)

            def with_source_language_note(answer) = fact_renderer.with_source_language_note(answer)

            def with_result_evidence(answer, result, include_source: true, omit_warning: nil)
              fact_renderer.with_result_evidence(answer, result, include_source:, omit_warning:)
            end

            def public_neighborhood_summary?(result) = fact_renderer.public_neighborhood_summary?(result)

            def neighborhood_summary_text(result, facts) = fact_renderer.neighborhood_summary_text(result, facts)

            def single_source(result) = fact_renderer.single_source(result)

            def safe_url?(value) = fact_renderer.safe_url?(value)

            # The rendering half is FactRenderer#available_read; a compacted
            # answer already carries its own provenance, so only the plain
            # fact list gets the result evidence appended.
            def render_available_read(result)
              facts = validated_facts(result)
              return render_empty_available_read(result) if facts.empty?

              rendered = fact_renderer.available_read(result, facts)
              evidence = PriorEvidence.capture(result:, facts:, action:, topic:, now: context.now, expires_at: state.fetch("expires_at"))
              answer = rendered.compact ? rendered.text : with_result_evidence(rendered.text, result, include_source: false)
              finish(answer, resolution: "answered", facts: fact_ids(facts), prior_evidence: evidence)
            end

            # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
            def refresh_member_evidence(evidence, locale:)
              area_slug = evidence.dig("scope", "area_slugs")&.first
              return unless area_slug

              current = read(action: evidence.fetch("action"), topic: evidence.fetch("topic"), entities: { "area_slug" => area_slug }, location: nil, locale:)
              return unless %w(ok stale).include?(current.status) && current.coverage.is_a?(Hash) && current.coverage["visibility"] == "member_board"
              return unless current.coverage["area_slugs"] == [area_slug]

              facts = validated_facts(current)
              retained = evidence.fetch("facts").map { |fact| fact.fetch("id") }
              return unless (retained - fact_ids(facts)).empty?

              retained_facts = facts.select { |fact| retained.include?(fact.fetch("id")) }
              PriorEvidence.capture(result: current, facts: retained_facts, action: evidence.fetch("action"), topic: evidence.fetch("topic"),
                                    now: context.now, expires_at: evidence.fetch("expires_at"))
            rescue Contracts::Invalid
              nil
            end
            # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

            def evidence_source_reply(evidence, locale:)
              sources = evidence.fetch("facts").map { |fact| fact["source_label"] || fact.fetch("source_id") }.uniq.join("; ")
              key = evidence.fetch("kind") == "member_board" ? "prior_evidence_current_member_source" : "prior_evidence_source"
              t(key, locale:, source: sources)
            end

            # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
            def evidence_date_reply(evidence, locale:)
              scope = evidence.fetch("scope")
              requested_window = %w(service_day starts_at ends_at).filter_map { |key| scope[key] }

              parts = [member_evidence_lead(evidence, locale:)].compact
              parts << t("prior_evidence_requested_window", locale:, time: human_window(requested_window, locale:)) unless requested_window.empty?
              evidence.fetch("facts").each_with_index do |fact, index|
                source = fact["source_label"] || fact.fetch("source_id")
                label = t("prior_evidence_fact_label", locale:, index: index + 1, source:)
                validity = %w(service_day starts_at ends_at valid_until).filter_map { |key| fact[key] }
                parts << if validity.empty?
                           t("prior_evidence_fact_validity_unknown", locale:, fact: label)
                         else
                           t("prior_evidence_fact_validity", locale:, fact: label, time: human_window(validity, locale:))
                         end
                parts << t("prior_evidence_fact_observed_at", locale:, fact: label, time: human_time(fact["observed_at"], locale:)) if fact["observed_at"]
                parts << t("prior_evidence_fact_checked_at", locale:, fact: label, time: human_time(fact["checked_at"], locale:)) if fact["checked_at"]
                %w(reviewed_on source_published_at source_updated_at).each do |key|
                  parts << "#{label}: #{t("fact_#{key}", locale:, time: human_time(fact[key], locale:))}" if fact[key]
                end
              end
              parts.empty? ? t("prior_evidence_date_unknown", locale:) : parts.join("\n")
            end
            # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

            def human_window(values, locale:)
              values.uniq.map { |value| human_time(value, locale:) }.join("; ")
            end

            def evidence_locale
              text = message.respond_to?(:text) ? message.text.to_s : message.to_s
              return "sr-Cyrl" if text.match?(/\p{Cyrillic}/)

              folded = Decidim::Bih::Text.fold(text)
              return "en" if ENGLISH_EVIDENCE_FOLLOW_UPS.include?(folded)

              %w(sr bs hr).include?(state.fetch("locale")) ? state.fetch("locale") : "sr"
            end

            def member_evidence_lead(evidence, locale:)
              return unless evidence.fetch("kind") == "member_board"

              t("prior_evidence_current_member_read", locale:)
            end

            def evidence_disagreement_reply(evidence, locale:)
              reply = member_evidence_lead(evidence, locale:)
              [reply, t("prior_evidence_disagreement", locale:, url: destination("report"))].compact.join("\n")
            end

            # The label for a read with no facts is Resolution's decision, not
            # this call site's: Task 9b revisits it in one place.
            def render_empty_available_read(result)
              return own_reports_empty_answer(result) if own_reports_empty?(result)

              stale = result.status == "stale"
              refuse(result, key: stale ? "stale" : "no_match", resolution: Resolution.empty_available_read(stale:))
            end

            # "You have no reports on this account yet" is a SCOPED ZERO-RESULT
            # ANSWER, not "I have no verified data": the reader looked, in the
            # citizen's own account, and there was nothing there. ReadPort
            # already returns the distinct +no_owned_reports+ warning; this is
            # the half of the repair that stops rendering it as the generic
            # refusal. (The other half is the FactRenderer warning key, which
            # this task does not own.)
            def own_reports_empty?(result)
              action == "report_status" && result.warnings.include?("no_owned_reports")
            end

            # No source footer: the reader looked in the citizen's own account,
            # so there is no external source, area or window to qualify — and
            # "Odgovor važi samo za navedeni izvor, područje i vrijeme" is
            # nonsense under this answer. (The warning key that FactRenderer
            # would otherwise fall back from is Task 7's file, not this one.)
            def own_reports_empty_answer(_result)
              finish(t("own_reports_empty", url: destination("report")),
                     resolution: Resolution.empty_read(complete: true))
            end

            def fact_ids(facts)
              facts.map { |fact| fact.fetch("id") }
            end

            def validate_handoff!(result)
              raise Contracts::Invalid, "Typed handoff required" unless result.is_a?(Contracts::HandoffResult)

              # V1 has no actor/revision-bound return contract. Never treat a
              # bare boolean as authority to enable automatic draft resumption.
              raise Contracts::Invalid, "Unsupported resumable handoff" if result.resume_supported
            end

            def handoff_unavailable?(result)
              (result.expires_at && result.expires_at <= context.now) || !result.destination
            end

            def unavailable_handoff
              finish(t("handoff_unavailable", url: destination("account")), resolution: "unsupported")
            end

            def handoff_answer(result)
              key = result.completed ? "account_observed" : "handoff_#{result.next_step}"
              key = "handoff_next_step" unless I18n.exists?("decidim.bih.dialogue.#{key}", state.fetch("locale"))
              answer = t(key, url: result.destination)
              answer += "\n\n#{t("resume_manual")}" if !result.resume_supported && (state["suspended_task"] || state["draft"])
              answer
            end

            def ambiguity_slot(result)
              return "stop" if topic == "transport" && result.warnings.intersect?(%w(transport_origin_required transport_origin_ambiguous))
              return "area_query" if topic == "transport" && result.warnings.include?("transport_destination_ambiguous")

              warnings = result.warnings.join(" ")
              return "time_expression" if warnings.match?(/time|date|day/)
              return "reference" if action == "report_status"
              return "stop" if topic == "transport" && !entities["stop"]

              "area_query"
            end

            def answer_intent
              return "report_guidance" if action == "report_problem"
              return "status" if action == "report_status"
              return "setup" if REGISTRATION_ACTIONS.include?(action) || registration_area_selection?
              return "komsiluk_read" if action == "neighborhood_information"
              return "komsiluk_post" if action == "neighborhood_post"
              return "local_area_guidance" if action == "choose_area"

              TOPIC_ANSWER_INTENTS.fetch(topic, "service")
            end

            def registration_area_selection?
              action == "choose_area" && topic == "account"
            end
          end
        end
      end
    end
  end
end

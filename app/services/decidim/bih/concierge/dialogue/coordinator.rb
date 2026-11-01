# frozen_string_literal: true

require_relative "state_store"
require_relative "turn_budget"
require_relative "admission_control"
require_relative "procedure_runner"
require_relative "fact_renderer"
require_relative "civic_question"
require_relative "transport_follow_up_question"
require_relative "public_information"
require_relative "answer_context"
require_relative "answer_continuation"
require_relative "question_queue"
require_relative "pre_model_stages"
require_relative "procedure_question"
require_relative "understand"
require_relative "courtesy"
require_relative "text_predicates"
require_relative "../emergency_card"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Composes existing typed ports without giving the model execution
        # authority. All effects remain disabled; CAS governs semantic state.
        class Coordinator
          CORE_TOPICS = %w(waste water electricity transport parking heating roads city_service neighborhood account report unknown
                           air_quality water_levels police sistem48 weather civil_protection bulky_waste
                           donation budget gazette volunteer participation community public_calls facilities rewards
                           health social_welfare agriculture permits education animals).freeze
          # The shared dialogue vocabulary lives in TextPredicates; these names stay for external references.
          CANCEL_COMMANDS = TextPredicates::CANCEL_COMMANDS
          CANCEL_FIRST_CLAUSE = TextPredicates::CANCEL_FIRST_CLAUSE
          NEW_QUESTION_START = /\A(?:kako|gdje|gde|sta|sto|koji|koja|koje|koliko|kada|kad|mogu li|da li|how|where|what|which|when|can i)\b/
          # A question the coordinator lifted out of a longer message: the
          # clause after a cancellation, or the positive half of a contrastive
          # correction. +follow_up+ says the coordinator has ALREADY
          # established that this clause continues the conversation, which is
          # what lets AnswerContinuation waive its ellipsis shape for it.
          FreshQuestion = Data.define(:text, :follow_up) do
            def initialize(text:, follow_up: false) = super

            def image_url = nil

            def latitude = nil

            def longitude = nil
          end
          # StateStore::TASK_KEYS minus "locale", at their empty_state values.
          FRESH_TASK = {
            "active_task" => nil, "topic" => "unknown", "pending_slot" => nil, "entities" => {},
            "entity_provenance" => {}, "draft" => nil, "report_handoff_offered" => false, "clarification_count" => 0
          }.freeze
          LOCAL_REPAIR_PHRASES = TextPredicates::LOCAL_REPAIR_PHRASES
          ENGLISH_REPAIR_PHRASES = TextPredicates::ENGLISH_REPAIR_PHRASES
          EVIDENCE_FOLLOW_UPS = {
            "source" => ["odakle ti to", "odakle ti je to", "одакле ти то", "одакле ти је то", "where did you get that", "what is the source"],
            "date" => ["za koji datum vazi", "za koji datum ovo vazi", "за који датум важи", "за који датум ово важи", "what date is this for", "when does this apply"],
            "disagreement" => ["nije tako kod mene", "nije tako ovdje", "није тако код мене", "није тако овдје", "that is not true where i am", "that is not the case here"]
          }.freeze
          # The same three questions, phrased the way people actually phrase
          # them. Still whole-utterance matches: a sentence that asks something
          # ELSE as well is a new question and keeps going to understanding.
          EVIDENCE_FOLLOW_UP_SHAPES = {
            "source" => /\A(?:a[ ])?(?:odakle[ ](?:ti[ ])?(?:je[ ])?(?:to|ta[ ]informacija|taj[ ]podatak)|
                            (?:koji[ ]je[ ]|sta[ ]je[ ])?izvor(?:[ ]za[ ]to|[ ]toga)?|
                            gdje[ ](?:to[ ])?pise|gde[ ](?:to[ ])?pise|
                            where[ ]did[ ]you[ ](?:get|find)[ ](?:that|this)|what[ ]is[ ]the[ ]source)\z/x,
            "date" => /\A(?:a[ ])?(?:za[ ]koji[ ]datum[ ](?:ovo[ ])?(?:vazi|je)|
                          (?:od|za)[ ]kada[ ](?:to[ ])?vazi|na[ ]koji[ ](?:se[ ])?(?:datum|dan)[ ]odnosi|
                          what[ ]date[ ]is[ ]this[ ]for|when[ ]does[ ](?:this|that)[ ]apply)\z/x,
            "disagreement" => /\A(?:a[ ])?(?:(?:to[ ])?nije[ ]tako[ ](?:kod[ ]mene|ovdje|ovde|kod[ ]nas)|
                                  (?:kod[ ]mene|kod[ ]nas|ovdje|ovde)[ ](?:to[ ])?nije[ ]tako|
                                  that[ ]is[ ]not[ ]true[ ]where[ ]i[ ]am|that[ ]is[ ]not[ ]the[ ]case[ ]here)\z/x
          }.freeze
          WALKING_STOP_REFERENCE = /(?:(?:te|tog|toga|naj?blize|naj?blizeg|predlozene|predlozenog|polazne|polaznog|izabrane|odabrane|ulazne)\s+){0,2}
                                    (?:autobuske\s+|autobuskog\s+)?(?:stanice|stajalista)/x
          WALKING_STOP_REQUEST = /\A(?:
            (?:(?:kako\s+(?:da\s+|mogu\s+)?(?:pjeske\s+|peske\s+|pjesice\s+)?(?:stignem|dodjem|dodem|idem))|
               (?:(?:mozes\s+li|mozete\s+li)\s+)?(?:me\s+)?(?:uputiti|uputis)|
               (?:otvori|pokazi|daj|posalji)\s+(?:mi\s+)?(?:put|rutu|navigaciju|link|mapu|kartu)|pjeske|peske|pjesice)
              \s+do\s+#{WALKING_STOP_REFERENCE}|
            kako\s+(?:da\s+|mogu\s+)?do\s+#{WALKING_STOP_REFERENCE}\s+(?:da\s+)?
              (?:stignem|stici|dodjem|dodem|idem)\s+(?:pjeske|peske|pjesice|pesice)|
            (?:otvori|pokazi|daj|posalji)\s+(?:mi\s+)?(?:pjesacku\s+|pesacku\s+)?(?:rutu|navigaciju|mapu|kartu)
              \s+(?:bas\s+)?do\s+#{WALKING_STOP_REFERENCE}
              (?:\s+(?:gdje|gde)\s+ulazim\s+u\s+(?:taj\s+)?autobus)?|
            (?:(?:moze\s+li|daj\s+mi|posalji\s+mi)\s+)?(?:uputstv[oa]|upute)\s+(?:kako\s+)?
              (?:(?:pjeske|peske|pjesice|pesice)\s+)?do\s+#{WALKING_STOP_REFERENCE}|
            (?:(?:how\s+(?:do|can)\s+i\s+walk)|open\s+(?:the\s+)?map|(?:(?:can|could)\s+you\s+)?(?:show|send|give)\s+me\s+(?:walking\s+directions|a\s+walking\s+link))
              \s+to\s+(?:(?:the|that)(?:\s+(?:nearest|suggested|boarding))?|nearest|suggested|boarding)\s+bus\s+stop
          )\z/x

          class Settings
            def initialize(env: ENV)
              @env = env
            end

            def model_override
              value = @env["MILICA_CONVERSATION_MODEL"].to_s
              return nil if value.empty?

              value if value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}\z/)
            end

            def v1_enabled_for?(context:, user:)
              return false unless context.is_a?(Contracts::TrustedContext) && valid_configuration?
              return false unless valid_actor_scope?(context, user)
              return true if audience == "public"
              return false unless matching_actor?(context, user)

              audience == "staff" ? staff?(user) : cohort.include?(context.actor_id)
            rescue StandardError
              false
            end

            private

            def valid_configuration?
              @env.fetch("MILICA_DIALOGUE_ENABLED", "false") == "true" &&
                %w(staff cohort public).include?(audience) && cohort &&
                @env.fetch("MILICA_COMPOSITION_ENABLED", "false") == "false" &&
                @env.fetch("MILICA_CONVERSATIONAL_WRITES_ENABLED", "false") == "false" &&
                (@env["MILICA_CONVERSATION_MODEL"].to_s.empty? || model_override)
            end

            def audience = @env.fetch("MILICA_DIALOGUE_AUDIENCE", "staff")

            def staff?(user)
              user.respond_to?(:admin?) && user.admin? == true
            end

            def valid_actor_scope?(context, user)
              (!user && !context.actor_id) || matching_actor?(context, user)
            end

            def cohort
              value = @env.fetch("MILICA_DIALOGUE_COHORT_USER_IDS", "")
              return [] if value.empty?
              return nil unless value.bytesize <= 4000 && value.match?(/\A[1-9]\d*(?:,[1-9]\d*)*\z/)

              value.split(",").map(&:to_i).uniq
            end

            def matching_actor?(context, user)
              user && user.respond_to?(:id) && user.id == context.actor_id &&
                user.respond_to?(:organization) && user.organization&.id == context.organization_id
            end
          end

          # Also used by the safe legacy web brain. Never wraps identity/token
          # writes: their owning channel/backend must handle them before entry.
          class Runtime
            THREAD_KEY = :decidim_bih_milica_turn_budget
            MODEL_DENIED_KEY = :decidim_bih_milica_model_denied

            def initialize(admission: AdmissionControl.new, timeout: 9.0)
              @admission = admission
              @timeout = timeout
            end

            def self.current_budget = Thread.current[THREAD_KEY]

            def self.model_allowed? = Thread.current[MODEL_DENIED_KEY] != true

            def self.without_model
              previous = Thread.current[MODEL_DENIED_KEY]
              Thread.current[MODEL_DENIED_KEY] = true
              yield
            ensure
              Thread.current[MODEL_DENIED_KEY] = previous
            end

            def call
              budget = TurnBudget.new(timeout: @timeout)
              @admission.with_slot(deadline: budget) do
                previous = Thread.current[THREAD_KEY]
                begin
                  Thread.current[THREAD_KEY] = budget
                  yield budget
                ensure
                  Thread.current[THREAD_KEY] = previous
                end
              end
            rescue Understand::ProviderUnavailable
              # The coordinator names this failure to the citizen; the lease is
              # already released by the admission control's ensure.
              raise
            rescue StandardError => e
              reason = self.class.failure_reason(e)
              failure_site = self.class.failure_site(e)
              self.class.record_failure(stage: "runtime", error: e, reason:, failure_site:)
              AdmissionControl::Result.new(status: :unavailable, phase: :runtime, reason:, failure_site:)
            end

            # One line per swallowed failure with a closed reason token: a provider or
            # transport message may quote a key, a phone number or a payload.
            # No metrics write here: the coordinator runs inside the offline
            # evaluation's no-side-effect boundary, and the reply boundary
            # already records the outcome from the result's resolution.
            CONTRACT_FAILURES = {
              "Expected bounded contract text" => "contract_text",
              "Entity provenance mismatch" => "contract_provenance",
              "Unsupported contract enum" => "contract_enum",
              "Unexpected contract field" => "contract_field",
              "Invalid clarification count" => "contract_clarification",
              "Invalid opaque draft fields" => "contract_draft",
              "Invalid opaque draft reference" => "contract_draft_reference",
              "Report handoff requires report task" => "contract_report_handoff"
            }.freeze
            PROVIDER_FAILURES = %w(unconfigured budget timeout malformed transport).to_h { |reason| [reason, "provider_#{reason}"] }.freeze

            def self.failure_reason(error)
              return PROVIDER_FAILURES.fetch(error.reason, "provider_unavailable") if error.is_a?(Understand::ProviderUnavailable)
              return CONTRACT_FAILURES.fetch(error.message, "contract_invalid") if error.is_a?(Contracts::Invalid)

              "internal_error"
            end

            def self.failure_site(error)
              location = Array(error.backtrace_locations).find do |candidate|
                path = candidate.absolute_path || candidate.path
                path&.match?(%r{/app/services/(?:decidim/bih/concierge|decidim_app/bijeljina/milica)/})
              end
              return nil unless location

              file = File.basename(location.absolute_path || location.path, ".rb").gsub(/[^a-z0-9_]/i, "_").downcase
              label = location.base_label.to_s.gsub(/[^a-zA-Z0-9_?!]/, "_")
              value = "#{file}:#{location.lineno}:#{label}"
              AdmissionControl::Result::FAILURE_SITE.match?(value) ? value : nil
            rescue StandardError
              nil
            end

            def self.record_failure(stage:, error:, reason: failure_reason(error), failure_site: failure_site(error), logger: default_logger)
              fields = ["[MilicaCoordinator] stage=#{stage}", "error=#{error.class.name}", "reason=#{reason}"]
              fields << "failure_site=#{failure_site}" if failure_site
              logger&.warn(fields.join(" "))
              nil
            rescue StandardError
              nil
            end

            def self.default_logger
              Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
            end
          end

          # A conversation-only adapter; it cannot mutate the shared Gemini
          # default model or allow a caller to extend the whole-turn deadline.
          class BudgetedClient
            class MissingBudget < StandardError; end

            def initialize(client:)
              @client = client
            end

            def configured?
              Runtime.model_allowed? && @client.configured?
            end

            def generate_content(**arguments)
              budget = Runtime.current_budget
              raise MissingBudget, "Conversation budget required" unless budget && !budget.expired? && Runtime.model_allowed?

              child = budget.within(6.0)
              value = Timeout.timeout(child.remaining_seconds, AdmissionControl::WorkTimeout) do
                @client.generate_content(**arguments, timeout: child.remaining_seconds)
              end
              raise AdmissionControl::WorkTimeout, "Conversation model deadline expired" if child.expired?

              value
            end
          end

          # A known, reviewed deterministic read adapter, not an agent/tool loop.
          # Its responder must be built without an LLM classifier or write port.
          class LegacyReadAdapter
            READ_INTENTS = %w(budget gazette donation goodwill data_status launch participation_guidance volunteer_guidance local_area_guidance service waste).freeze
            Result = Data.define(:reply, :resolution)

            def initialize(responder:)
              @responder = responder
            end

            def call(message:, understanding:)
              raise Contracts::Invalid, "Secondary read intent required" unless understanding.action == "ask_information"

              # The turn's language travels with the delegation. Without it the
              # legacy brain re-derives the locale from the message's script,
              # which can only say Latin or Cyrillic — so an English (or bs/hr)
              # conversation had its budget, gazette, Goodwill and launch cards
              # answered in Serbian while the rest of the reply was not.
              locale = understanding.locale
              reply = Responder.with_reply_locale(locale) { Runtime.without_model { @responder.respond(message) } }
              raise Contracts::Invalid, "Read-only legacy reply required" unless reply.is_a?(Responder::Reply) && reply.report.nil?

              clean = Responder::Reply.new(text: reply.text, report: nil, sticker: nil, quick_replies: reply.quick_replies,
                                           answer_intent: reply.answer_intent, tone: reply.tone, phrase_id: reply.phrase_id,
                                           locale:)
              resolution = READ_INTENTS.include?(clean.answer_intent) && !clean.text.to_s.strip.empty? ? "answered" : "unsupported"
              Result.new(reply: clean, resolution:)
            end
          end

          # The locale of a reply that has no saved conversation locale to
          # follow: a Cyrillic message is answered in Cyrillic, otherwise the
          # request's UI locale (Decidim sets I18n.locale per request from the
          # user's or the organisation's locale) when Milica speaks it, else
          # Serbian. Latin bs, hr and sr cannot be told apart from the text.
          def self.locale_for(message)
            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            return "sr-Cyrl" if text.match?(/\p{Cyrillic}/)

            current = I18n.locale.to_s
            Contracts::LOCALES.include?(current) ? current : "sr"
          end

          CONTROL_INTENTS = {
            "safety" => "safety", "allegation" => "moderation", "clarify" => "help", "credentials" => "setup",
            "greeting" => "help", "closure" => "help", "thanks" => "help", "farewell" => "help", "capabilities" => "help"
          }.freeze

          # Safety, credentials and allegations always win; a courtesy is a
          # whole-utterance match and is answered before admission without
          # touching state. Thanks and farewells never cancel anything.
          def self.control_reply(message:)
            key = control_key(message)
            return unless key

            translation = key == "allegation" ? "decidim.bih.concierge.safety.allegation" : "decidim.bih.dialogue.#{key}"
            tone = Courtesy::KINDS.include?(key) ? "neighborly" : "core"
            locale = control_locale(message, key)
            text = (control_emergency_card(message) if key == "safety") || I18n.t(translation, locale:)
            Responder::Reply.new(text:, report: nil, answer_intent: CONTROL_INTENTS.fetch(key), tone:, locale:)
          end

          # A control reply is composed before any state is read, so the saved
          # conversation locale is not available here and #locale_for falls back
          # to I18n.locale — the language of the PAGE. For a courtesy that is
          # wrong often enough to matter: an English "hello", "thanks", "what
          # can you do?" or a bare "help" was answered from the Serbian card,
          # because the site is Serbian. Both lookups below read the language
          # off the closed alternative that actually matched, so nothing is
          # guessed and no free text is language-detected.
          #
          # Only a courtesy and the help keyword are decided this way. Safety,
          # credentials and allegations are free citizen text with no closed
          # vocabulary to read a language from, and a guess there would be a
          # guess about an emergency; they keep the site's locale.
          def self.control_locale(message, key)
            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            hint = if Courtesy::KINDS.include?(key)
                     Courtesy.locale_hint(text)
                   elsif key == "clarify" && Responder::ENGLISH_HELP_KEYWORDS.include?(Decidim::Bih::Text.fold(text.strip))
                     "en"
                   end
            hint || locale_for(message)
          end

          # The coordinator-only boundary (Viber's dialogue_turn, and the web
          # whenever the report conversation is not wrapping the turn) used to
          # answer EVERY danger with the all-services card, while the report
          # path this host actually takes already names the relevant service.
          # Typed danger now gets the same card here; untyped danger keeps the
          # all-services card, where the police and the SOS line ARE the answer.
          def self.control_emergency_card(message)
            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            EmergencyCard.typed(text, fallback_locale: locale_for(message))
          rescue StandardError
            nil
          end

          def self.control_key(message)
            text = message.respond_to?(:text) ? message.text.to_s.strip : message.to_s.strip
            folded = Decidim::Bih::Text.fold(text)
            return "credentials" if StateStore.sensitive_text?(text)
            return "safety" if safety?(message, folded)
            return "allegation" if Responder::LEGAL_ALLEGATION_KEYWORDS.any? { |word| folded.include?(word) }

            Courtesy.kind(text) || ("clarify" if Responder::HELP_KEYWORDS.include?(folded))
          end

          def self.safety?(message, _folded)
            return true if message.respond_to?(:safety_signal?) && message.safety_signal? == true

            Responder.immediate_danger?(message.respond_to?(:text) ? message.text : message.to_s)
          end

          def self.cancelled?(message)
            return true if message.respond_to?(:cancel?) && message.cancel? == true

            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            ProcedureRunner.cancellation_wording?(text) || StateStore.clear_command?(text)
          end

          def self.prior_evidence_kind(message)
            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            folded = Decidim::Bih::Text.fold(text)
            EVIDENCE_FOLLOW_UPS.each do |kind, phrases|
              return kind if phrases.any? { |phrase| folded == Decidim::Bih::Text.fold(phrase) }
            end
            EVIDENCE_FOLLOW_UP_SHAPES.each { |kind, shape| return kind if shape.match?(folded) }
            nil
          end

          def initialize(understanding:, procedures:, state_store: StateStore.new, runtime: Runtime.new, legacy_secondary: nil)
            raise Contracts::Invalid, "Deterministic legacy read adapter required" unless legacy_secondary.nil? || legacy_secondary.is_a?(LegacyReadAdapter)

            @understanding = understanding
            @procedures = procedures
            @state_store = state_store
            @runtime = runtime
            @legacy_secondary = legacy_secondary
          end

          def call(message:, context:)
            raise Contracts::Invalid, "Trusted conversation scope required" unless context.is_a?(Contracts::TrustedContext)

            control = self.class.control_reply(message:)
            cancellation = self.class.cancelled?(message)
            return result(control, resolution: control_resolution(control, message)) if control && !cancellation

            protection = protected_control_reply(control, cancellation:)
            admitted = @runtime.call do |budget|
              execute(message:, context: context.with(deadline: budget))
            end
            return protected_result(admitted.value, protection) if admitted.admitted? && admitted.value.is_a?(ProcedureRunner::Result)

            protected_result(failure(message, admitted.status == :capacity ? "busy" : "context_unavailable"), protection)
          rescue Understand::ProviderUnavailable => e
            # No state was written: the provider failed before any procedure
            # ran, so the citizen is told that and asked to retry, nothing else.
            Runtime.record_failure(stage: "understanding", error: e)
            protected_result(failure(message, "provider_unavailable", resolution: "provider_unavailable"), protection)
          rescue StandardError => e
            Runtime.record_failure(stage: "coordinator", error: e)
            protected_result(failure(message, "context_unavailable"), protection)
          end

          private

          def execute(message:, context:)
            state = @state_store.read(context:)
            return failure(message, "context_unavailable") if !state || context.deadline.expired?

            state = seed_locale(message, state)
            # "A drugo pitanje?" names one of the citizen's OWN earlier
            # questions, so it is lifted before anything else can classify it
            # from two words of ordinal. It declines unless that question is
            # actually on the queue, and a decline falls through to exactly
            # the turn this used to be.
            queued = queued_question(message, state)
            return execute_with_state(message: queued, context:, state:) if queued

            # "nastavi" with nothing suspended still has somewhere to go when
            # the citizen asked more than one question in a message. The STASH
            # is tried first (ProcedureRunner#resume_suspended_task, through
            # resume_with_nothing_suspended?); only when it is empty does the
            # QUEUE answer. See QuestionQueue's comment for which owns what.
            resumed = queue_resume_question(message, state)
            return execute_with_state(message: resumed.fetch(:question), context:, state: resumed.fetch(:state)) if resumed

            question = cancellation_question(message)
            return cancel_then_question(message:, question:, state:, context:) if question

            correction = correction_question(message, state)
            return execute_with_state(message: correction.fetch(:question), context:, state: correction.fetch(:state)) if correction

            seeded = seed_question_queue(message, state, context:)
            offer_queued_questions(execute_with_state(message:, context:, state: seeded), seeded:, state:)
          end

          # The resume word, answered from the citizen's own unanswered
          # questions. nil unless this turn IS the resume word, nothing is
          # suspended, and the queue still holds a question the resume word has
          # not handed out — in which case the turn falls through to
          # "Nemam sačuvano pitanje", exactly as it did before.
          #
          # The cursor is advanced in the state this turn then saves, so a
          # second "nastavi" moves to the next question rather than repeating
          # one. An ordinal request ("A drugo pitanje?") leaves it alone: the
          # citizen navigating their own list by number is not consuming it.
          def queue_resume_question(message, state)
            return unless resume_with_nothing_suspended?(message, state)

            queue = state[StateStore::QUESTION_QUEUE_KEY]
            question = QuestionQueue.next_unserved(queue)
            return if question.nil? || question.strip.empty?

            { question: FreshQuestion.new(text: question, follow_up: true),
              state: state.merge(StateStore::QUESTION_QUEUE_KEY => QuestionQueue.advance(queue)) }
          end

          # Teach the word on the turn that creates something to resume. The
          # stash makes this offer from the runner when it suspends a task; a
          # message carrying several questions suspends nothing (a reviewed
          # card answers before the model and writes no task), so the offer had
          # nowhere to come from and the citizen was never told "nastavi"
          # existed. Made once, on the turn the queue is opened.
          #
          # Never on a clarification (there is nothing answered to come back
          # from), never on a danger answer, and never twice in one reply.
          def offer_queued_questions(answered, seeded:, state:)
            return answered if seeded.equal?(state) || !answered.is_a?(ProcedureRunner::Result)
            return answered unless Resolution.offers_resume?(answered.resolution)

            reply = answered.reply
            return answered if reply.nil? || reply.answer_intent == "safety" || reply.text.to_s.strip.empty?

            offer = I18n.t("decidim.bih.dialogue.resume_offer", locale: answered_locale(answered, state), raise: true)
            return answered if reply.text.include?(offer)

            offered = reply.dup
            offered.text = "#{reply.text}\n\n#{offer}"
            answered.with(reply: offered)
          rescue I18n::ArgumentError
            answered
          end

          def answered_locale(answered, state)
            saved = answered.state.is_a?(Hash) ? answered.state["locale"] : nil
            saved || state["locale"] || "sr"
          end

          # The citizen's own other questions, from the message this turn is
          # about to answer. Seeded BEFORE the turn runs, so whichever writer
          # the turn uses carries it into the state it saves — no second CAS,
          # and no writer has to know about it.
          #
          # Best effort and additive: a message that asks one question leaves
          # whatever queue is already there alone, because a queue outlives the
          # turn that opened it (that is the whole point of "A treće?"). A
          # cancellation clears it, like everything else, by rebuilding the
          # state from empty_state.
          def seed_question_queue(message, state, context:)
            captured = QuestionQueue.capture(
              message_text(message), now: context.now, state_expires_at: state.fetch("expires_at")
            )
            return state if captured.nil?
            # Where to transfer and how long to wait describe the same retained
            # journey. Both facets are answered together, so neither is saved
            # as another task. Every part must qualify; mixed-topic lists stay.
            if state.values_at("active_task", "topic") == %w(ask_information transport) && !state["draft"] &&
               TransportFollowUpQuestion.complementary_transfer_questions?(captured.fetch("questions"))
              return state
            end

            state.merge(StateStore::QUESTION_QUEUE_KEY => captured)
          end

          # The queued question as a FreshQuestion, or nil. +follow_up+ is set
          # because the coordinator has established this continues the
          # conversation — the citizen said so, by ordinal.
          def queued_question(message, state)
            return if message.respond_to?(:cancel?) && message.cancel? == true
            return if self.class.control_reply(message:) || self.class.cancelled?(message)

            ordinal = TextPredicates.queued_question_ordinal(Text.fold(message_text(message)))
            return if ordinal.nil?

            question = QuestionQueue.question_at(state[StateStore::QUESTION_QUEUE_KEY], ordinal)
            return if question.nil? || question.strip.empty?

            FreshQuestion.new(text: question, follow_up: true)
          end

          # A conversation with no saved turn starts in the locale the citizen
          # is already reading the site in; the fresh state itself stays
          # locale-neutral ("sr") because it is also built outside a request.
          # Once a turn is saved, the saved locale stands and the message's
          # script decides (Understand#locale_for).
          def seed_locale(message, state)
            return state unless state.fetch("version").zero? && state["active_task"].nil?

            state.merge("locale" => self.class.locale_for(message))
          end

          # The hand-ordered pre-model checks now live in PreModelStages, which
          # owns their order; this walks that list before any provider work.
          def execute_with_state(message:, context:, state:)
            staged = PreModelStages.walk(stage_turn(message:, context:, state:))
            return staged if staged

            input = fast_understanding(message, state) || @understanding.call(
              message:, state:, history: StateStore.prune_history(message_history(message), now: context.now), deadline: context.deadline
            )
            return failure(message, "context_unavailable") if context.deadline.expired?
            return secondary_result(message, input, state, context:) if secondary?(input)

            candidate = @procedures.call(understanding: input, state:, context:, message:)
            accept_candidate(candidate, message:, context:, state:)
          end

          # A pre-model stage reaches the coordinator only through this seam:
          # the procedures object plus the bound helpers below, nothing else.
          def stage_turn(message:, context:, state:)
            support = PreModelStages::Support.new(
              procedures: @procedures,
              cancelled: self.class.method(:cancelled?),
              prior_evidence_kind: self.class.method(:prior_evidence_kind),
              accept: method(:accept_candidate),
              unavailable: method(:failure),
              resume_nothing: method(:resume_nothing),
              resume_with_nothing_suspended: method(:resume_with_nothing_suspended?),
              walking_stop_request: method(:walking_stop_request?),
              retain_answer: method(:retain_answer_context)
            )
            PreModelStages::Turn.new(message:, context:, state:, support:)
          end

          def walking_stop_request?(message)
            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            text.length <= 200 && !self.class.cancelled?(message) && WALKING_STOP_REQUEST.match?(Text.fold(text))
          end

          # A courtesy is an answered turn; the other help-intent control reply
          # (a bare "help"/"pomoć") is still a clarification.
          def control_resolution(control, message)
            return Resolution::SAFETY_GUIDANCE if control.answer_intent == "safety"

            return "unsupported" unless control.answer_intent == "help"

            Courtesy.kind(message_text(message)) ? "answered" : "clarification"
          end

          # "nastavi" with nothing to resume is answered deterministically and
          # keeps the state as it is: no model call, no CAS write, and no
          # clarification spent. It used to require that NO task was open
          # either, so repeating "nastavi" after a resume went to the model and
          # came back as the identical question, charged to the budget.
          #
          # The two deterministic continuations that genuinely mean "next" —
          # report-status paging and a public-activity refinement — still own
          # the word and are checked first.
          def resume_with_nothing_suspended?(message, state)
            return false unless ProcedureRunner::RESUME_COMMANDS.include?(message_text(message).strip.downcase)
            return false if state["suspended_task"] || report_status_paging?(state)

            ProcedureRunner.public_activity_continuation_input(
              text: message_text(message).strip, state:, locale: self.class.locale_for(message)
            ).nil?
          end

          def report_status_paging?(state)
            state["active_task"] == "report_status" && OwnReportQuestion.limit(state.fetch("entities")["query"])
          end

          def resume_nothing(message, state)
            text = I18n.t("decidim.bih.dialogue.resume_nothing", locale: self.class.locale_for(message))
            result(Responder::Reply.new(text:, report: nil, answer_intent: "help", tone: "neighborly"), resolution: "answered", state:)
          end

          def message_text(message)
            message.respond_to?(:text) ? message.text.to_s : message.to_s
          end

          def cancellation_question(message)
            return if message.respond_to?(:cancel?) && message.cancel? == true
            return if self.class.control_reply(message:)

            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            first, question = text.split(/[.!;\n]\s*|,\s*(?=(?:kako|šta|sta|gdje|gde|how|what|where)\b)/i, 2)
            return unless question && TextPredicates.cancel_first_clause?(Decidim::Bih::Text.fold(first))
            return unless Decidim::Bih::Text.fold(question).match?(NEW_QUESTION_START)
            return if self.class.cancelled?(question)

            FreshQuestion.new(text: question.strip)
          end

          def cancel_then_question(message:, question:, state:, context:)
            candidate = @procedures.call(understanding: fast_understanding("cancel", state), state:, context:, message:)
            cancelled = accept_candidate(candidate, message:, context:, state:)
            return cancelled unless cancelled.resolution == "cancelled"

            # Commit cancellation before any provider work. The second CAS
            # starts from that clean version, never the report's slots/history.
            fresh = cancelled.state.merge("version" => state.fetch("version") + 1)
            answered = execute_with_state(message: question, context:, state: fresh)
            reply = answered.reply.dup
            prefix = I18n.t("decidim.bih.dialogue.cancelled_then_next", locale: cancelled.state.fetch("locale"), raise: true)
            reply.text = "#{prefix}\n\n#{reply.text}"
            answered.with(reply:)
          end

          # == A repair carries information; use it
          #
          # "Ne pitam za parking. Pitam da li je korišćenje ove platforme
          # besplatno." The citizen named what was wrong AND what they meant,
          # and got 512 more characters of parking. A repair like that is not a
          # request for another clarifying question: the positive half IS the
          # question, and the negated half says which subject must not answer
          # it.
          #
          # Two outcomes, and no third. When the negated subject is the one the
          # conversation is actually on, that subject is DROPPED here - the
          # task, its slots and the retained answer are all cleared before the
          # positive half is answered, so it cannot be re-served. When the
          # citizen negated something narrower ("Ne pitam za liniju"), the
          # subject stands and only the FACET moves: the positive half is
          # answered as a follow-up inside it.
          #
          # nil when this is not a contrastive correction, when it carries no
          # positive half (a bare "Nisam to pitala." still gets the repair
          # question, because there is genuinely nothing to recover), or when
          # the conversation holds work this may not touch.
          # The shape is checked FIRST, so the precedence guards below - which
          # re-run the card selection and the deterministic routes - are paid
          # for only by the turns that actually look like a correction.
          def correction_question(message, state)
            return if message.respond_to?(:cancel?) && message.cancel? == true

            text = message_text(message)
            return if TransportLocationPreferenceStage.handles?(text:, state:)

            parts = TextPredicates.contrastive_correction(text)
            positive = correction_request(parts)
            return if positive.nil? || !correctable?(message, text, state)

            { question: FreshQuestion.new(text: positive, follow_up: true),
              state: negates_current_subject?(parts["negated"], state) ? subject_free_state(state) : state }
          end

          # Safety, credentials, a courtesy and an actual cancellation are all
          # decided before this and keep their own paths. So does an explicit
          # request a reviewed card or a deterministic route already answers,
          # exactly as it does for a continuation: "Ne, pitam šta je
          # MI PRE(D)UZIMAMO? Prvi put sam ovdje." is the newcomer question,
          # not a correction whose second sentence is the request.
          def correctable?(message, text, state)
            return false if self.class.control_reply(message:) || self.class.cancelled?(message)
            return false if PublicInformation.card(text) || CivicQuestion.classify(text)

            correctable_task?(state)
          end

          # The half of the correction that asks for something, or nil when it
          # has none: a bare "Nisam to pitala." recovers nothing.
          def correction_request(parts)
            positive = parts && parts["positive"]
            return unless positive.is_a?(String) && positive.match?(/\p{L}/) && !StateStore.sensitive_text?(positive)

            positive.strip
          end

          # A correction may re-aim a question. It may never reach past one
          # into an unfinished report, a live draft or a pending confirmation:
          # those belong to the report path and keep their own repair. An
          # opaque draft IS the pending confirmation - it holds the reference
          # the citizen is looking at - so its presence alone refuses this.
          def correctable_task?(state)
            return false if state["draft"]

            [nil, "ask_information"].include?(state["active_task"])
          end

          # Does the negated subject name what the conversation is on? Compared
          # against the citizen's OWN retained words (the saved query and the
          # retained answer's anchor) as well as the topic token, because the
          # topic token is English and the citizen is not: "smeće" never
          # matches "waste", but it does match the question they asked.
          def negates_current_subject?(negated, state)
            tokens = negated.to_s.split(/\s+/).select { |token| token.length >= 4 }
            return false if tokens.empty?

            retained = state[AnswerContext::KEY]
            haystack = [state["topic"], state.fetch("entities", {})["query"],
                        retained.is_a?(Hash) ? retained["topic"] : nil,
                        retained.is_a?(Hash) ? retained["anchor"] : nil].compact
            folded = haystack.map { |value| Decidim::Bih::Text.fold(value.to_s) }.join(" ")
            tokens.any? { |token| folded.include?(token[0, [token.length, 5].min]) }
          end

          # The same state with the answered subject removed: no task, no
          # slots, no retained answer, and no retained evidence to re-render.
          # Everything else - the version this turn must still CAS against, the
          # suspended task, the conversation clock - is untouched. FRESH_TASK is
          # every TASK_KEY except the locale, which belongs to the citizen and
          # not to the subject; the ownership test pins that correspondence.
          def subject_free_state(state)
            state.merge(FRESH_TASK).merge("prior_evidence" => nil, AnswerContext::KEY => nil)
          end

          # A pre-model stage retains what it just ANSWERED, and nothing else.
          # Best effort on purpose: a refused CAS loses the continuity hint and
          # keeps the answer the citizen already read. The write refreshes the
          # conversation clock exactly as an ordinary answered turn does.
          #
          # +presentation_level+ is the brevity level the stage RENDERED at, so
          # a second "kraće" on the same card is shorter than the first instead
          # of identical to it. It is stored under the state store's own key,
          # with the same rule the two answered-turn writers in ProcedureRunner
          # use: a level equal to the renderer's default is stored as nil,
          # because nil reads back as the default and writing it would churn
          # the CAS-versioned store on every ordinary turn. This stays inside
          # the SAME best-effort write on purpose — going through +turn.accept+
          # instead would turn a refused CAS into a failure reply on a card the
          # citizen has already been answered with, trading a lost preference
          # for a lost answer.
          def retain_answer_context(state:, context:, presentation_level: nil, locale: nil, **attributes)
            now = context.now.to_f
            expires = now + Contracts::CONTEXT_TTL
            captured = AnswerContext.capture(now: context.now, state_expires_at: expires, **attributes)
            return state if captured.nil?

            state = state.merge("locale" => locale) if Contracts::LOCALES.include?(locale)
            candidate = state.merge("updated_at" => now, "expires_at" => expires, AnswerContext::KEY => captured)
            candidate = candidate.merge(StateStore::PRESENTATION_LEVEL_KEY => retained_level(presentation_level)) unless presentation_level.nil?
            @state_store.write(context:, state: candidate, expected_version: state.fetch("version")) == :saved ? candidate : state
          rescue Contracts::Invalid
            state
          end

          # An unknown token is dropped rather than raised, exactly as the
          # state store's own normalizer does: a presentation preference must
          # never be able to destroy the conversation around it.
          def retained_level(level)
            return unless StateStore::PRESENTATION_LEVELS.include?(level)

            level unless level == FactRenderer::DEFAULT_LEVEL
          end

          def accept_candidate(candidate, message:, context:, state:)
            return failure(message, "context_unavailable") if context.deadline.expired?

            saved = @state_store.write(context:, state: candidate.state, expected_version: state.fetch("version"))
            return candidate if saved == :saved && !context.deadline.expired?

            failure(message, saved == :conflict ? "context_changed" : "context_unavailable")
          end

          def protected_control_reply(control, cancellation:)
            return unless cancellation && control
            return if control.answer_intent == "help"

            control
          end

          def protected_result(candidate, reply)
            return stamped(candidate) unless reply
            return protected_safety_result(candidate, reply) if reply.answer_intent == "safety"

            raise Contracts::Invalid, "Cancellation or failure result required" unless %w(cancelled unsupported busy provider_unavailable
                                                                                          safety_guidance).include?(candidate.resolution)

            protected_reply = Responder::Reply.new(
              text: [candidate.reply.text, reply.text].join("\n\n"),
              report: nil,
              quick_replies: reply.quick_replies,
              answer_intent: candidate.resolution == "cancelled" ? reply.answer_intent : candidate.reply.answer_intent,
              tone: reply.tone,
              phrase_id: reply.phrase_id,
              locale: candidate.reply.locale || reply.locale
            )
            stamped(ProcedureRunner::Result.new(
                      state: candidate.state,
                      reply: protected_reply,
                      resolution: candidate.resolution,
                      fact_ids: [],
                      handoff_offered: false,
                      handoff_completed: false
                    ))
          end

          def protected_safety_result(candidate, control)
            response = candidate.reply.answer_intent == "safety" ? candidate.reply : control
            diagnostics = candidate.diagnostics.is_a?(Hash) ? candidate.diagnostics.dup : {}
            diagnostics["admission_resolution"] = candidate.resolution unless candidate.resolution == Resolution::SAFETY_GUIDANCE
            stamped(ProcedureRunner::Result.new(
                      state: candidate.state, reply: response, resolution: Resolution::SAFETY_GUIDANCE,
                      fact_ids: [], handoff_offered: false, handoff_completed: false, diagnostics:
                    ))
          end

          # Every reply leaves the coordinator carrying the language it is
          # written in. The dialogue already decided that language and saved it
          # on the turn; without it on the reply, the channel layer reads
          # I18n.locale instead — the language of the page, not of the citizen —
          # and decorates an English answer with Serbian.
          #
          # A reply that already states its locale (a control reply) keeps it,
          # and a state that carries no usable locale leaves the reply saying
          # nothing rather than claiming Serbian.
          def stamped(result)
            reply = result.reply
            return result unless reply.respond_to?(:locale) && reply.locale.nil?

            state = result.state
            locale = state["locale"] if state.is_a?(Hash)
            reply.locale = locale if Contracts::LOCALES.include?(locale)
            result
          end

          def fast_understanding(message, state)
            text = message.respond_to?(:text) ? message.text.to_s.strip.downcase : message.to_s.strip.downcase
            locale = state.fetch("locale")
            if self.class.cancelled?(message)
              return Contracts::Understanding.parse(action: "cancel", topic: "unknown", entities: {}, operation: "cancel",
                                                    needs_clarification: false, secondary: nil, locale:)
            end
            return Contracts::Understanding.clarify(locale:) if ProcedureRunner.resume_request?(raw_text(message), state)

            presentation = presentation_understanding(message, state, locale)
            return presentation if presentation

            raw = raw_text(message)
            if (stop = TransportQuestionRoute.navigation_stop_answer(raw, state))
              return Contracts::Understanding.parse(action: "ask_information", topic: "transport", entities: { "query" => raw, "stop" => stop },
                                                    operation: "continue", needs_clarification: false, secondary: nil,
                                                    locale: self.class.locale_for(message))
            end
            if TransportQuestionRoute.navigation_follow_up?(raw, state)
              return Contracts::Understanding.parse(action: "ask_information", topic: "transport", entities: {},
                                                    operation: "continue", needs_clarification: false, secondary: nil,
                                                    locale: self.class.locale_for(message))
            end
            if AccountQuestion.missing_message_follow_up?(raw, state)
              return Contracts::Understanding.parse(action: "ask_information", topic: "account", entities: { "query" => raw },
                                                    operation: "continue", needs_clarification: false, secondary: nil,
                                                    locale: self.class.locale_for(message))
            end
            if TextPredicates.read_follow_up_kind(raw, state)
              return Contracts::Understanding.parse(action: "ask_information", topic: state.fetch("topic"), entities: {},
                                                    operation: "continue", needs_clarification: false, secondary: nil,
                                                    locale: self.class.locale_for(message))
            end
            activity = ProcedureRunner.public_activity_continuation_input(text: raw, state:, locale: self.class.locale_for(message))
            return activity if activity

            if ProcedureRunner::RESUME_COMMANDS.include?(text) && state["active_task"] == "report_status" &&
               OwnReportQuestion.limit(state.fetch("entities")["query"])
              return Contracts::Understanding.parse(action: "report_status", topic: "report", entities: {}, operation: "continue",
                                                    needs_clarification: false, secondary: nil, locale:)
            end

            if state["active_task"] == "report_status" && !state["draft"] && (OwnReportQuestion.correction?(text) || OwnReportQuestion.reference_missing?(text))
              return Contracts::Understanding.parse(action: "report_status", topic: "report", entities: { "query" => "moje prijave" },
                                                    operation: "continue", needs_clarification: false, secondary: nil,
                                                    locale: self.class.locale_for(message))
            end
            if OwnReportQuestion.limit(text)
              operation = state["active_task"] && state["active_task"] != "report_status" ? "switch" : "start"
              return Contracts::Understanding.parse(action: "report_status", topic: "report", entities: { "query" => text },
                                                    operation:, needs_clarification: false, secondary: nil, locale: self.class.locale_for(message))
            end

            if (journey = TransportFollowUpQuestion.call(raw, state:)) && !CivicQuestion.classify(raw)
              return Contracts::Understanding.parse(**journey, locale: self.class.locale_for(message))
            end

            if (read = CivicQuestion.classify(message.respond_to?(:text) ? message.text.to_s : message.to_s))
              same_task = state["active_task"] == read.fetch(:action) && state["topic"] == read.fetch(:topic)
              operation = state["active_task"] && !same_task ? "switch" : "start"
              return Contracts::Understanding.parse(**read, operation:, needs_clarification: false, secondary: nil,
                                                            locale: self.class.locale_for(message))
            end

            if state["active_task"] == "choose_area" && state["pending_slot"] == "area_query" &&
               CivicQuestion.mz_contact?(state.fetch("entities")["query"]) && (area = Procedures::Komsiluk.area_answer(text))
              return Contracts::Understanding.parse(action: "choose_area", topic: "neighborhood", operation: "continue",
                                                    entities: { "query" => state.fetch("entities").fetch("query"), "area_query" => area },
                                                    needs_clarification: false, secondary: nil, locale: self.class.locale_for(message))
            end

            continued_or_repaired(message, state)
          end

          # The last two deterministic chances before the provider: continue the
          # subject the previous turn answered, or treat this as a repair.
          def continued_or_repaired(message, state)
            continuation_understanding(message, state) || repair_understanding(message, state)
          end

          # THE follow-up owns the turn. It sits here, after every cheap check
          # above it, so an explicit new subject, a cancellation, a return
          # request, a presentation request, report-status paging and an area
          # answer all keep precedence over any continuation - and before the
          # repair and the model, which are the two paths that used to answer
          # "A kad se zavrsava trka?" with the rewards catalogue.
          def continuation_understanding(message, state)
            found = AnswerContinuation.resolve(
              text: raw_text(message), state:,
              follow_up: message.respond_to?(:follow_up) && message.follow_up == true
            )
            read = found&.read
            return if read.nil?

            same_task = state["active_task"] == read.fetch(:action) && state["topic"] == read.fetch(:topic)
            operation = state["active_task"] && !same_task ? "switch" : "start"
            Contracts::Understanding.parse(**read, operation:, needs_clarification: false, secondary: nil,
                                                   locale: self.class.locale_for(message))
          rescue Contracts::Invalid
            nil
          end

          def raw_text(message)
            message.respond_to?(:text) ? message.text.to_s.strip : message.to_s.strip
          end

          # "kraće" / "detaljnije" is a presentation operation on the answer
          # already given: the same task, the same question, rendered to a
          # different budget. It must never reach the model, where it came back
          # as a clarification or — worse — as a cancellation.
          def presentation_understanding(message, state, locale)
            return unless TextPredicates.presentation_request?(Decidim::Bih::Text.fold(raw_text(message)))

            locale = TextPredicates.presentation_locale(raw_text(message)) || (raw_text(message).match?(/\p{Cyrillic}/) ? "sr-Cyrl" : locale)
            action, topic = presentation_subject(state)
            return unless action && topic
            return if ProcedureRunner::CONTROL_ACTIONS.include?(action)

            Contracts::Understanding.parse(action:, topic:, entities: {},
                                           operation: "continue", needs_clarification: false, secondary: nil, locale:)
          end

          # The open task owns a "kraće" when there is one. When the last reply
          # was an ANSWER that opened no task, the retained answer context is
          # what the request is about - without it, "može odgovor u najviše
          # dvije rečenice?" was re-classified from scratch and came back
          # longer than the answer it asked to shorten.
          def presentation_subject(state)
            return state.values_at("active_task", "topic") if state["active_task"] && state["topic"]

            retained = state[AnswerContext::KEY]
            retained.is_a?(Hash) ? retained.values_at("action", "topic") : [nil, nil]
          end

          # Whole-utterance matches only: a correction containing new details
          # still needs understanding so those details are not discarded.
          # A repair preserves the task; it never means publication or cancel.
          def repair_understanding(message, state)
            text = message.respond_to?(:text) ? message.text.to_s : message.to_s
            folded = Decidim::Bih::Text.fold(text)
            english = TextPredicates.english_repair_phrase?(folded)
            return unless english || TextPredicates.local_repair_phrase?(folded)

            locale = if english
                       "en"
                     elsif text.match?(/\p{Cyrillic}/)
                       "sr-Cyrl"
                     else
                       %w(sr bs hr).include?(state["locale"]) ? state["locale"] : "sr"
                     end
            Contracts::Understanding.parse(
              action: state["active_task"] || "help", topic: state.fetch("topic"), entities: {},
              operation: "correct", needs_clarification: true, secondary: nil, locale:
            )
          end

          def message_history(message)
            message.respond_to?(:conversation_context) ? message.conversation_context : []
          end

          def secondary?(input)
            @legacy_secondary && input.action == "ask_information" && CORE_TOPICS.none? { |topic| topic == input.topic }
          end

          # The legacy read adapter answers a real question, so its turn owns
          # the conversation afterwards. It used to write NO state at all — it
          # is the only answering path that never reached accept_candidate — so
          # the next turn was classified against the task the citizen had
          # already left, and the turn log reported that superseded task's
          # action, topic and entity keys.
          def secondary_result(message, input, state, context:)
            legacy = @legacy_secondary.call(message:, understanding: input)
            return failure(message, "context_unavailable") if context.deadline.expired?

            reply = shortened_secondary_reply(legacy.reply, message, state, context:)
            saved = secondary_state(message, input, state, context:)
            return result(reply, resolution: legacy.resolution, state:) unless saved

            candidate = result(reply, resolution: legacy.resolution, state: saved)
            accepted = accept_candidate(candidate, message:, context:, state:)
            # A refused CAS must not turn an answered read into a failure: the
            # read happened, and the next turn reads the newer saved state.
            accepted.equal?(candidate) ? accepted : result(reply, resolution: legacy.resolution, state:)
          end

          def secondary_state(message, input, state, context:)
            return nil unless @procedures.respond_to?(:secondary_state)

            @procedures.secondary_state(understanding: input, state:, context:, message:)
          rescue Contracts::Invalid
            nil
          end

          # A brevity request about a legacy answer is a presentation operation
          # on that answer, not a new read and not a second model call.
          def shortened_secondary_reply(reply, message, state, context:)
            return reply unless @procedures.respond_to?(:shorten_reply)
            return reply unless TextPredicates.presentation_request?(Decidim::Bih::Text.fold(raw_text(message)))

            shortened = @procedures.shorten_reply(reply.text, state:, context:, message:)
            return reply if shortened.to_s == reply.text.to_s

            Responder::Reply.new(text: shortened, report: nil, quick_replies: reply.quick_replies,
                                 answer_intent: reply.answer_intent, tone: reply.tone, phrase_id: reply.phrase_id)
          rescue StandardError
            reply
          end

          # A capacity refusal resolves as "busy" and a provider failure as
          # "provider_unavailable" so the metrics can tell them from a citizen
          # request the platform does not support.
          def failure(message, key, resolution: nil)
            locale = self.class.locale_for(message)
            # The provider copy falls back to the context copy until the
            # locale key is merged; both merge orders must render.
            text = I18n.t("decidim.bih.dialogue.#{key}", locale:, default: [:"decidim.bih.dialogue.context_unavailable"])
            reply = Responder::Reply.new(text:, report: nil, answer_intent: "fallback", tone: "core", locale:)
            result(reply, resolution: resolution || (key == "busy" ? "busy" : "unsupported"))
          end

          def result(reply, resolution:, state: nil)
            ProcedureRunner::Result.new(state:, reply:, resolution:, fact_ids: [], handoff_offered: false, handoff_completed: false)
          end
        end
      end
    end
  end
end

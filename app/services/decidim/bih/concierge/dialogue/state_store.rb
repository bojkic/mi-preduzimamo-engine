# frozen_string_literal: true

require "json"
require "redis"
require "digest"
require "decidim/bih/redis_endpoint"
require_relative "contracts"
require_relative "prior_evidence"
require_relative "answer_context"
require_relative "question_queue"
require_relative "conversation_frame"
require_relative "conversation_slots"
require_relative "text_predicates"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Semantic state has its own namespace; it never extends or clears the
        # ten-minute OTP/linking store. No retrieved private facts are retained.
        class StateStore
          KEY_PREFIX = "decidim-bih:milica:dialogue:v1"
          MAX_BYTES = 12_000
          # RESERVED, versioned: bounded emergency continuity. Task 2 is its
          # only writer; nothing writes it yet. The version is in the key name,
          # so a later shape change is a new key and an old row simply stops
          # matching (fail closed) instead of being reinterpreted.
          #
          # Lifetime and clearing, all enforced here on every read and write:
          #   * expiry        — dropped once +expires_at+ has passed, and it may
          #                     never be set more than SAFETY_CONTEXT_TTL after
          #                     +opened_at+ nor outlive the conversation state;
          #   * turns         — dropped above SAFETY_CONTEXT_MAX_TURNS, so it
          #                     cannot follow a citizen through a conversation;
          #   * real topic change — it records the topic it was opened under and
          #                     is dropped as soon as the state's topic differs;
          #   * explicit resolution — the writer stores nil, and nothing here
          #                     ever resurrects a cleared context;
          #   * conversation clear — the whole Redis value is deleted, and a
          #                     fresh conversation starts from empty_state.
          # Anything malformed is dropped rather than raised: a continuity hint
          # must never be able to destroy the conversation state around it.
          #
          # Scope: the value lives under a key already scoped to organization,
          # actor and conversation, and it is deliberately NOT in TASK_KEYS, so
          # a suspended task never carries it.
          SAFETY_CONTEXT_KEY = "safety_context_v1"
          SAFETY_CONTEXT_FIELDS = %w(kind topic opened_at expires_at turns).freeze
          SAFETY_CONTEXT_TTL = 10 * 60
          SAFETY_CONTEXT_MAX_TURNS = 3
          SAFETY_CONTEXT_KIND = /\A[a-z][a-z0-9_]{0,39}\z/
          # How verbose the last answer was rendered, so a second "kraće" is
          # actually shorter than the first. A closed token, never text: the
          # authoritative list is FactRenderer::LEVELS, repeated here so the
          # state store stays independent of the renderer. An unknown value is
          # dropped (the renderer then falls back to its own default) rather
          # than raising — a presentation preference must never be able to
          # destroy the conversation around it.
          PRESENTATION_LEVEL_KEY = "presentation_level"
          PRESENTATION_LEVELS = %w(full default short brief).freeze
          # WHAT the last reply answered, as opposed to what the citizen is
          # DOING. AnswerContext owns its shape, its lifetime and its privacy
          # rules; the store only enforces them on every read and write. Like
          # the safety context it is deliberately NOT in TASK_KEYS, so a
          # suspended task never carries one, and a malformed value is dropped
          # rather than raised.
          ANSWER_CONTEXT_KEY = AnswerContext::KEY
          # The OTHER questions the citizen asked in the message this turn is
          # answering — their own words, in their own order. QuestionQueue owns
          # its shape, its lifetime and its bounds; the store only enforces
          # them on every read and write. Like the safety context and the
          # retained answer it is deliberately NOT in TASK_KEYS, so a suspended
          # task never carries one, and a malformed value is dropped rather
          # than raised.
          QUESTION_QUEUE_KEY = QuestionQueue::KEY
          # How far up the four-way top-level menu's ladder THIS conversation
          # has already climbed: 0 the menu, 1 "which service?", 2 the support
          # route. Deliberately NOT in TASK_KEYS and deliberately not
          # clarification_count: the model labels two consecutive unplaceable
          # turns as two fresh tasks, each of which resets the clarification
          # budget, which is how the menu came back byte-identical instead of
          # escalating. The conversation remembers the offer even when the task
          # does not.
          TOPIC_MENU_KEY = "topic_menu_step"
          TOPIC_MENU_STEPS = 2
          STATE_KEYS = (%w(
            schema_version version active_task topic pending_slot entities
            entity_provenance suspended_task draft prior_evidence report_handoff_offered resume_offered locale clarification_count created_at updated_at expires_at
          ) + [SAFETY_CONTEXT_KEY, PRESENTATION_LEVEL_KEY, ANSWER_CONTEXT_KEY, QUESTION_QUEUE_KEY, TOPIC_MENU_KEY, ConversationFrame::KEY, ConversationSlots::KEY]).freeze
          TASK_KEYS = %w(active_task topic pending_slot entities entity_provenance draft report_handoff_offered locale clarification_count).freeze
          RESET_SCRIPT = <<~LUA
            if redis.call('GET', KEYS[1]) == ARGV[1] then
              return redis.call('DEL', KEYS[1])
            end
            return 0
          LUA
          WRITE_SCRIPT = <<~LUA
            local current = redis.call('GET', KEYS[1])
            local version = 0
            if current then
              local ok, decoded = pcall(cjson.decode, current)
              if not ok or type(decoded) ~= 'table' then return -1 end
              version = tonumber(decoded.version) or -1
            end
            if version ~= tonumber(ARGV[1]) then return 0 end
            redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
            return 1
          LUA

          def initialize(redis: nil)
            @redis = redis
          end

          def read(context:)
            storage_key = key(context)
            2.times do
              raw = redis.get(storage_key)
              return empty_state(context) if raw.nil?

              begin
                raise Contracts::Invalid, "Invalid stored state" unless raw.is_a?(String) && raw.bytesize <= MAX_BYTES

                return normalize_state(JSON.parse(raw), now: context.now)
              rescue Contracts::Invalid, JSON::ParserError
                # Delete only the invalid value observed, never a newer turn.
                removed = redis.eval(RESET_SCRIPT, keys: [storage_key], argv: [raw])
                return empty_state(context) if removed == 1
              end
            end
            nil # Concurrent replacement could not be read consistently.
          rescue Redis::BaseError, IOError, SystemCallError
            nil # Unavailable is distinct from a legitimate empty conversation.
          end

          def write(context:, state:, expected_version:)
            raise Contracts::Invalid, "Invalid state version" unless expected_version.is_a?(Integer) && expected_version >= 0

            validated = normalize_state(state, now: context.now)
            raise Contracts::Invalid, "State/version mismatch" unless validated.fetch("version") == expected_version

            candidate = validated.merge("version" => expected_version + 1)
            encoded = JSON.generate(candidate)
            raise Contracts::Invalid, "Dialogue state too large" if encoded.bytesize > MAX_BYTES

            ttl = [(candidate.fetch("expires_at") - context.now.to_f).ceil, Contracts::CONTEXT_TTL].min
            result = redis.eval(WRITE_SCRIPT, keys: [key(context)], argv: [expected_version, encoded, ttl])
            result == 1 ? :saved : :conflict
          rescue Contracts::Invalid
            :invalid
          rescue Redis::BaseError, IOError, SystemCallError
            :unavailable
          end

          def clear(context:)
            redis.del(key(context))
            true
          rescue Redis::BaseError, IOError, SystemCallError
            false
          end

          # Server-side handoff stores use this typed key only to check the
          # exact dialogue revision atomically with consuming their own ticket.
          def revision_key(context:)
            key(context)
          end

          def empty_state(context)
            now = context.now.to_f
            {
              "schema_version" => Contracts::VERSION, "version" => 0,
              "active_task" => nil, "topic" => "unknown", "pending_slot" => nil,
              "entities" => {}, "entity_provenance" => {}, "suspended_task" => nil,
              "draft" => nil, "prior_evidence" => nil, "report_handoff_offered" => false, "resume_offered" => false,
              "locale" => "sr", "clarification_count" => 0, "created_at" => now,
              "updated_at" => now, "expires_at" => now + Contracts::CONTEXT_TTL,
              SAFETY_CONTEXT_KEY => nil, PRESENTATION_LEVEL_KEY => nil, ANSWER_CONTEXT_KEY => nil,
              QUESTION_QUEUE_KEY => nil, TOPIC_MENU_KEY => 0, ConversationFrame::KEY => nil,
              ConversationSlots::KEY => nil
            }
          end

          # Validate injected state without accessing Redis. Procedure execution
          # accepts only the same bounded shape as persistent state.
          def validate(context:, state:)
            raise Contracts::Invalid, "Trusted context required" unless context.is_a?(Contracts::TrustedContext)

            normalize_state(state, now: context.now)
          end

          # Shared legacy/v1 history policy. Cache TTL is not evidence that each
          # turn is young; validate timestamps even on a successful cache read.
          def self.prune_history(turns, now: Time.now.utc)
            Array(turns).last(Contracts::MAX_TURNS).filter_map do |turn|
              next unless turn.is_a?(Hash)

              value = turn.transform_keys(&:to_s)
              next unless fresh_timestamp?(value["at"], now:)
              next unless valid_history_pair?(value)

              bounded_history_turn(value)
            end
          end

          def self.valid_history_pair?(value)
            %w(user bot).all? do |key|
              text = value[key]
              text.is_a?(String) && text.valid_encoding? && text.length <= Contracts::MAX_MESSAGE_LENGTH &&
                !text.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f]/) && !sensitive_text?(text)
            end
          end

          def self.bounded_history_turn(value)
            bounded = value.slice("user", "bot", "at")
            %w(answer_intent tone phrase_id).each do |key|
              bounded[key] = value[key] if history_token?(value[key])
            end
            bounded["location_present"] = value["location_present"] == true
            bounded["tone_history"] = Array(value["tone_history"]).last(6).select { |token| history_token?(token) }
            bounded
          end

          def self.history_token?(token)
            token.is_a?(String) && token.match?(/\A[a-z0-9_.-]{1,80}\z/)
          end

          def self.fresh_timestamp?(value, now:, ttl: Contracts::CONTEXT_TTL)
            timestamp = Float(value)
            timestamp.finite? && timestamp.positive? && timestamp <= now.to_f && now.to_f - timestamp < ttl
          rescue ArgumentError, TypeError
            false
          end

          # A conservative pre-model credential boundary, not an identity
          # verifier. A year/date or category number remains normal dialogue.
          # The patterns live in TextPredicates; this stays the public entry point.
          def self.sensitive_text?(text)
            TextPredicates.credential?(text)
          end

          def self.clear_command?(text)
            %w(clear /clear).include?(text.to_s.strip.downcase) ||
              ["novi razgovor", "obriši razgovor", "obrisi razgovor", "new conversation", "нови разговор", "обриши разговор"].include?(text.to_s.strip.downcase)
          end

          private

          def redis
            @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url,
                                 connect_timeout: 0.2, read_timeout: 0.2, write_timeout: 0.2, reconnect_attempts: 0)
          end

          def key(context)
            raise Contracts::Invalid, "Trusted context required" unless context.is_a?(Contracts::TrustedContext)

            actor_scope = Digest::SHA256.hexdigest("actor:#{context.actor_id || "anonymous"}")[0, 24]
            "#{KEY_PREFIX}:#{context.organization_id}:#{actor_scope}:#{context.conversation_key}"
          end

          def normalize_state(state, now:)
            value = normalize_report_handoff(additive_defaults(Contracts.object!(state, STATE_KEYS)))
            raise Contracts::Invalid, "Incomplete state" unless (STATE_KEYS - value.keys).empty?
            raise Contracts::Invalid, "Unsupported state schema" unless value.fetch("schema_version") == Contracts::VERSION
            raise Contracts::Invalid, "Invalid state version" unless value.fetch("version").is_a?(Integer) && value.fetch("version") >= 0

            validate_state_times!(value, now:)
            validate_resume_offer!(value)
            validate_task!(value, now:)
            value["prior_evidence"] = PriorEvidence.normalize(
              value.fetch("prior_evidence"), now:, state_expires_at: value.fetch("expires_at")
            )
            value[SAFETY_CONTEXT_KEY] = normalize_safety_context(value, now:)
            value[PRESENTATION_LEVEL_KEY] = normalize_presentation_level(value.fetch(PRESENTATION_LEVEL_KEY))
            value[ANSWER_CONTEXT_KEY] = AnswerContext.normalize(
              value.fetch(ANSWER_CONTEXT_KEY), now:, state_expires_at: value.fetch("expires_at")
            )
            value[QUESTION_QUEUE_KEY] = QuestionQueue.normalize(
              value.fetch(QUESTION_QUEUE_KEY), now:, state_expires_at: value.fetch("expires_at")
            )
            value[ConversationFrame::KEY] = ConversationFrame.normalize(value[ConversationFrame::KEY], now: now, state_expires_at: value.fetch("expires_at"))
            value[ConversationSlots::KEY] = ConversationSlots.normalize(
              value[ConversationSlots::KEY], now:, state_expires_at: value.fetch("expires_at")
            )
            value[TOPIC_MENU_KEY] = normalize_topic_menu_step(value.fetch(TOPIC_MENU_KEY))
            suspended = value.fetch("suspended_task")
            unless suspended.nil?
              suspended = Contracts.object!(suspended, TASK_KEYS)
              suspended = normalize_report_handoff(suspended)
              raise Contracts::Invalid, "Incomplete suspended task" unless suspended.keys.sort == TASK_KEYS.sort
              raise Contracts::Invalid, "Invalid suspended action" if [nil, "help", "safety", "cancel"].include?(suspended["active_task"])

              validate_task!(suspended, now:)
              value["suspended_task"] = suspended
            end
            Contracts.snapshot(value)
          end

          # Evidence and the once-only resume offer marker are additive to the
          # short-lived Redis schema. A valid turn saved before either field
          # existed must not be thrown away: it has no evidence and has not
          # been offered a resume yet.
          # A step outside the ladder is not a stored step: an old conversation,
          # or a value this schema never wrote, starts the ladder at the menu.
          def normalize_topic_menu_step(step)
            step.is_a?(Integer) && step.between?(0, TOPIC_MENU_STEPS) ? step : 0
          end

          # rubocop:disable Metrics/CyclomaticComplexity -- one default per optional state field, applied in a single pass
          def additive_defaults(value)
            value = value.merge("prior_evidence" => nil) unless value.has_key?("prior_evidence")
            value = value.merge("resume_offered" => false) unless value.has_key?("resume_offered")
            value = value.merge(SAFETY_CONTEXT_KEY => nil) unless value.has_key?(SAFETY_CONTEXT_KEY)
            value = value.merge(PRESENTATION_LEVEL_KEY => nil) unless value.has_key?(PRESENTATION_LEVEL_KEY)
            value = value.merge(ANSWER_CONTEXT_KEY => nil) unless value.has_key?(ANSWER_CONTEXT_KEY)
            value = value.merge(QUESTION_QUEUE_KEY => nil) unless value.has_key?(QUESTION_QUEUE_KEY)
            value = value.merge(ConversationFrame::KEY => nil) unless value.has_key?(ConversationFrame::KEY)
            value = value.merge(ConversationSlots::KEY => nil) unless value.has_key?(ConversationSlots::KEY)
            value = value.merge(TOPIC_MENU_KEY => 0) unless value.has_key?(TOPIC_MENU_KEY)
            value
          end
          # rubocop:enable Metrics/CyclomaticComplexity

          # See PRESENTATION_LEVEL_KEY: an unknown or malformed level is
          # dropped, never raised.
          def normalize_presentation_level(value)
            value if PRESENTATION_LEVELS.include?(value)
          end

          # See SAFETY_CONTEXT_KEY. Every rule is a drop, never a raise.
          # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- field-by-field validation of persisted safety context
          def normalize_safety_context(value, now:)
            context = value.fetch(SAFETY_CONTEXT_KEY)
            return nil unless context.is_a?(Hash)

            fields = context.transform_keys(&:to_s)
            return nil unless fields.keys.sort == SAFETY_CONTEXT_FIELDS.sort
            return nil unless fields.fetch("kind").is_a?(String) && fields.fetch("kind").match?(SAFETY_CONTEXT_KIND)
            return nil unless fields.fetch("topic") == value.fetch("topic")

            turns = fields.fetch("turns")
            return nil unless turns.is_a?(Integer) && turns.between?(0, SAFETY_CONTEXT_MAX_TURNS)

            valid_safety_window?(fields, now:, state_expires_at: Float(value.fetch("expires_at"))) ? fields : nil
          rescue ArgumentError, TypeError, KeyError
            nil
          end
          # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def valid_safety_window?(fields, now:, state_expires_at:)
            opened = Float(fields.fetch("opened_at"))
            expires = Float(fields.fetch("expires_at"))
            [opened, expires].all?(&:finite?) && opened.positive? && opened <= now.to_f &&
              now.to_f < expires && expires <= opened + SAFETY_CONTEXT_TTL && expires <= state_expires_at
          end

          def validate_resume_offer!(value)
            raise Contracts::Invalid, "Invalid resume offer marker" unless [true, false].include?(value.fetch("resume_offered"))
          end

          def normalize_report_handoff(value)
            return value if value.has_key?("report_handoff_offered")

            # Older form-guidance turns have no marker. Recover only complete
            # named-place reports; never infer GPS or an opaque draft's phase.
            entities = value["entities"]
            ready = value["active_task"] == "report_problem" && !value["draft"] && entities.is_a?(Hash) &&
                    !entities["description"].to_s.strip.empty? && %w(area_query area_slug street address).any? { |key| !entities[key].to_s.strip.empty? }
            value.merge("report_handoff_offered" => ready)
          end

          def validate_state_times!(value, now:)
            created = Float(value.fetch("created_at"))
            updated = Float(value.fetch("updated_at"))
            expires = Float(value.fetch("expires_at"))
            valid = [created, updated, expires].all?(&:finite?) && created.positive? &&
                    created <= updated && updated <= now.to_f && now.to_f < expires &&
                    expires <= updated + Contracts::CONTEXT_TTL
            raise Contracts::Invalid, "Expired or invalid state timestamps" unless valid
          rescue ArgumentError, TypeError
            raise Contracts::Invalid, "Invalid state timestamps"
          end

          def validate_task!(value, now:)
            task = value.fetch("active_task")
            Contracts.action_topic!(task, value.fetch("topic"), allow_nil_action: true)
            Contracts.enum!(value.fetch("locale"), Contracts::LOCALES)
            slot = value.fetch("pending_slot")
            Contracts.enum!(slot, Contracts::ENTITY_KEYS) unless slot.nil?
            validate_entities!(value)
            count = value.fetch("clarification_count")
            raise Contracts::Invalid, "Invalid clarification count" unless count.is_a?(Integer) && count.between?(0, 2)

            offered = value.fetch("report_handoff_offered")
            raise Contracts::Invalid, "Invalid report handoff marker" unless [true, false].include?(offered)
            raise Contracts::Invalid, "Report handoff requires report task" if offered && task != "report_problem"

            validate_draft!(value.fetch("draft"), now:)
          end

          def validate_entities!(value)
            entities = Contracts.object!(value.fetch("entities"), Contracts::ENTITY_KEYS)
            entities.each_value { |text| Contracts.text!(text, limit: 1000) }
            provenance = Contracts.object!(value.fetch("entity_provenance"), Contracts::ENTITY_KEYS)
            provenance.each_value { |source| Contracts.enum!(source, %w(citizen corrected validated_source trusted_profile)) }
            raise Contracts::Invalid, "Entity provenance mismatch" unless provenance.keys.sort == entities.keys.sort
            raise Contracts::Invalid, "Credential in dialogue state" if entities.values.any? { |text| self.class.sensitive_text?(text) }
          end

          def validate_draft!(draft, now:)
            return if draft.nil?

            fields = Contracts.object!(draft, %w(reference revision expires_at))
            raise Contracts::Invalid, "Invalid opaque draft fields" unless fields.keys.sort == %w(expires_at reference revision)

            Contracts.text!(fields["reference"], limit: 128)
            raise Contracts::Invalid, "Invalid opaque reference" unless fields["reference"].match?(/\A[A-Za-z0-9_-]{16,128}\z/)
            raise Contracts::Invalid, "Invalid draft revision" unless fields["revision"].is_a?(Integer) && fields["revision"] >= 0

            validate_draft_expiry!(fields["expires_at"], now:)
          end

          def validate_draft_expiry!(expires, now:)
            valid = expires.is_a?(Numeric) && expires.finite? && expires > now.to_f && expires <= now.to_f + Contracts::CONTEXT_TTL
            raise Contracts::Invalid, "Invalid draft expiry" unless valid
          end
        end
      end
    end
  end
end

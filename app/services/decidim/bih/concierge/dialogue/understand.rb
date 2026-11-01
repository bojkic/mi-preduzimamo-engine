# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "timeout"
require "yaml"
require_relative "contracts"
require_relative "stage_timing"
require_relative "understanding_cache"
require_relative "../../text"
require_relative "../../ai/error"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Converts one bounded citizen turn into the strict Understanding
        # contract. Model output is untrusted classification data: this class
        # never grants authority, confirms a write or executes an operation.
        class Understand
          DEFAULT_CONFIGURATION_PATH = File.expand_path(
            "../../../../../../config/concierge/milica_understanding_v1.yml",
            __dir__
          ).freeze
          MAX_PROVIDER_SECONDS = 6.0
          MAX_HISTORY_TEXT_LENGTH = 1000
          REQUIRED_CONFIGURATION_KEYS = %w(version max_understanding_seconds max_history_turns max_history_text_length system_instruction).freeze
          # The shipped rules stay within 8 000 characters; the optional local
          # lexicon is appended after them, so the combined instruction has its
          # own, larger bound.
          MAX_BASE_INSTRUCTION_LENGTH = 8_000
          MAX_INSTRUCTION_LENGTH = 10_000
          MAX_LEXICON_ENTRIES = 40
          MAX_LEXICON_TERM_LENGTH = 40
          MAX_LEXICON_MEANING_LENGTH = 80
          # Serbian noun endings a folded lexicon word may carry ("banderu",
          # "kaldrmi", "šahtovi", "đubreta"); a bare prefix is never enough, so
          # "sutra" does not hint bulky_waste and "kanton" does not hint waste.
          LEXICON_ENDINGS = "a|e|i|o|u|om|em|ama|ima|ovi|ova|ove|ovima|eta|etu|etom"
          LEXICON_STEM_MIN_LENGTH = 3
          # The reply is a small JSON classification, so its size is bounded;
          # sampling, thinking and the model id stay at the client's defaults.
          GENERATION_LIMITS = { max_output_tokens: 512, candidate_count: 1 }.freeze

          RESPONSE_SCHEMA = {
            type: "object",
            additionalProperties: false,
            required: %w(action topic entities operation needs_clarification secondary locale),
            properties: {
              action: { type: "string", enum: Contracts::ACTIONS },
              topic: { type: "string", enum: Contracts::TOPICS },
              entities: {
                type: "object",
                additionalProperties: false,
                # Keep this class usable in its pure-Ruby tests without relying
                # on ActiveSupport's index_with.
                properties: Contracts::ENTITY_KEYS.to_h { |key| [key, { type: "string" }] } # rubocop:disable Rails/IndexWith
              },
              operation: { type: "string", enum: Contracts::OPERATIONS },
              needs_clarification: { type: "boolean" },
              secondary: {
                type: "object",
                nullable: true,
                additionalProperties: false,
                required: %w(action topic),
                properties: {
                  action: { type: "string", enum: Contracts::ACTIONS },
                  topic: { type: "string", enum: Contracts::TOPICS }
                }
              },
              locale: { type: "string", enum: Contracts::LOCALES }
            }
          }.freeze

          # Matched against the folded whole utterance (Text.fold lowercases,
          # strips diacritics and punctuation and turns Cyrillic into Latin), so
          # "Нећу више!" and "necu vise" cancel alike while a longer question
          # that merely contains "neću" still reaches the model.
          CANCEL_PHRASES = ["odustani", "odustajem", "prekini", "prekid", "otkazi", "otkazujem", "cancel", "stop", "ne zelim", "necu", "necu vise"].freeze

          # Bare digits are only a secret while the conversation waits for one.
          AWAITING_SECRET_SLOTS = %w(reference code phone otp).freeze
          AWAITING_SECRET_TASKS = %w(verification link_account sign_in).freeze

          class ProviderTimeout < Timeout::Error; end

          # A failed provider is not an unclear citizen question. The reason is
          # a closed label for logs and counters; the message is fixed so no
          # provider detail (status text, key, payload) can travel with it.
          class ProviderUnavailable < StandardError
            REASONS = %w(unconfigured timeout malformed transport budget).freeze
            MESSAGE = "Understanding provider unavailable"

            attr_reader :reason

            def initialize(reason)
              raise ArgumentError, "Unknown provider failure reason" unless REASONS.include?(reason)

              @reason = reason
              super(MESSAGE)
            end
          end

          # SHA-256 of the effective system instruction, lexicon appendix
          # included: the cache key's prompt component, and a stable label for
          # "which prompt produced this classification".
          attr_reader :prompt_fingerprint

          # +cache+ defaults to the environment-flagged UnderstandingCache,
          # which is off unless MILICA_UNDERSTANDING_CACHE is set.
          def initialize(client:, configuration: nil, wall_clock: nil, cache: nil)
            @client = client
            @configuration = normalize_configuration(configuration || load_configuration)
            @wall_clock = wall_clock || -> { Time.now.utc }
            @cache = cache || UnderstandingCache.from_environment
            @prompt_fingerprint = Digest::SHA256.hexdigest(@configuration.fetch("system_instruction"))
          end

          def call(message:, state:, history:, deadline:)
            StageTiming.measure("understanding") { understand(message:, state:, history:, deadline:) }
          end

          # Topics whose local words (any script, with or without diacritics,
          # inflected) appear in +text+, in lexicon order and without "unknown".
          # Advisory only: the projection carries them and the model decides.
          def lexicon_hints(text)
            return EMPTY_HINTS unless text.is_a?(String) && !text.empty?

            folded = Text.fold(text[0, Contracts::MAX_MESSAGE_LENGTH])
            return EMPTY_HINTS if folded.empty?

            @configuration.fetch("lexicon").filter_map { |entry| entry.fetch("topic") if folded.match?(entry.fetch("pattern")) }
                          .uniq.reject { |topic| topic == "unknown" }.freeze
          end

          private

          EMPTY_HINTS = [].freeze

          def understand(message:, state:, history:, deadline:)
            text = message_text(message)
            locale = locale_for(state, text)
            return cancellation(locale:, state:) if cancellation?(message, text)
            return Contracts::Understanding.clarify(locale:) if bypass_model?(message, text, state)

            projection = state_projection(state, locale:, lexicon_topics: lexicon_hints(text))
            raise ProviderUnavailable, "unconfigured" unless configured?

            budget = provider_budget(deadline)
            raise ProviderUnavailable, "budget" unless budget && !budget.expired?

            # A hit replaces the provider call and nothing else; the write sits
            # outside the wall-clock guard so a slow Redis is never reported as
            # a provider timeout. Both are bounded by the cache's own timeouts.
            cache_key, cached = cached_understanding(message, text:, projection:, locale:, state:)
            return with_message_script(cached, text:, state:) if cached

            parsed = with_timeout(budget) do
              contents = prompt_contents(text:, projection:, history:, state:)
              parse_understanding(request_understanding(contents:, budget:))
            end
            remember_understanding(cache_key, parsed)
            with_message_script(parsed, text:, state:)
          rescue ProviderUnavailable
            # The coordinator answers with its provider-unavailable reply and
            # neither advances state nor spends the citizen's clarifications.
            raise
          rescue Timeout::Error
            raise ProviderUnavailable, "timeout"
          rescue StandardError
            # Only our own input validation is left here: an invalid message or
            # conversation state is a clarification, never a provider failure.
            Contracts::Understanding.clarify(locale: defined?(locale) ? locale : "sr")
          end

          private

          # Everything the client raises is a provider failure. Its message is
          # dropped on purpose: it may quote the HTTP body or the request.
          def request_understanding(contents:, budget:)
            @client.generate_content(
              contents:,
              response_schema: RESPONSE_SCHEMA,
              system_instruction: @configuration.fetch("system_instruction"),
              timeout: budget.remaining_seconds,
              generation_limits: GENERATION_LIMITS,
              retry_once: true
            )
          rescue Timeout::Error, ProviderUnavailable
            raise
          rescue JSON::ParserError
            raise ProviderUnavailable, "malformed"
          rescue StandardError
            raise ProviderUnavailable, "transport"
          end

          # [key, cached]: the key is nil when this turn must not touch the
          # cache, the value nil on a miss. The tenant/actor scope comes only
          # from the server-built trusted context the message carries; without
          # one there is no key. Secret-like, button and safety turns never
          # reach here (bypass_model? returned first), nor does a cancellation.
          def cached_understanding(message, text:, projection:, locale:, state:)
            scope = message.respond_to?(:trusted_context) ? message.trusted_context : nil
            key = @cache.key_for(scope:, text:, projection:, prompt_fingerprint: @prompt_fingerprint, locale:, state:)
            return [nil, nil] unless key

            [key, @cache.read(key)]
          end

          def remember_understanding(key, parsed)
            @cache.write(key, parsed) if key
          end

          # The strict contract rejecting a reply means the model did not answer
          # in the agreed shape; that is the provider's failure, not the citizen's.
          def parse_understanding(response)
            Contracts::Understanding.parse(response)
          rescue Contracts::Invalid, JSON::ParserError
            raise ProviderUnavailable, "malformed"
          end

          # The model tends to echo the conversation's script: a clearly Latin
          # follow-up after Cyrillic turns came back as sr-Cyrl in production.
          # The citizen's own script wins whenever it is clear; the model's
          # locale stands only for short or mixed messages.
          def with_message_script(parsed, text:, state:)
            case clear_script(text)
            when :cyrillic then parsed.locale == "sr-Cyrl" ? parsed : parsed.with(locale: "sr-Cyrl")
            when :latin then parsed.locale == "sr-Cyrl" ? parsed.with(locale: locale_for(state, text)) : parsed
            else parsed
            end
          end

          def load_configuration
            YAML.safe_load_file(DEFAULT_CONFIGURATION_PATH, aliases: false)
          end

          def normalize_configuration(value)
            config = Contracts.object!(value, REQUIRED_CONFIGURATION_KEYS + ["lexicon"])
            raise Contracts::Invalid, "Incomplete understanding configuration" unless REQUIRED_CONFIGURATION_KEYS.all? { |key| config.has_key?(key) }
            raise Contracts::Invalid, "Unsupported understanding configuration" unless config.fetch("version") == Contracts::VERSION

            lexicon = config.has_key?("lexicon") ? normalize_lexicon(config.fetch("lexicon")) : EMPTY_HINTS
            {
              "max_understanding_seconds" => positive_number!(config.fetch("max_understanding_seconds")),
              "max_history_turns" => bounded_integer!(config.fetch("max_history_turns"), maximum: Contracts::MAX_TURNS),
              "max_history_text_length" => bounded_integer!(config.fetch("max_history_text_length"), maximum: MAX_HISTORY_TEXT_LENGTH),
              "system_instruction" => system_instruction_with_lexicon(config.fetch("system_instruction"), lexicon),
              "lexicon" => lexicon
            }.freeze
          end

          # Without a lexicon the instruction is sent byte for byte; with one,
          # the appendix follows the shipped rules and the whole stays bounded.
          def system_instruction_with_lexicon(value, lexicon)
            base = Contracts.text!(value, limit: MAX_BASE_INSTRUCTION_LENGTH)
            return base if lexicon.empty?

            Contracts.text!("#{base.rstrip}\n\n#{lexicon_appendix(lexicon)}", limit: MAX_INSTRUCTION_LENGTH)
          end

          def lexicon_appendix(lexicon)
            entries = lexicon.map do |entry|
              rendered = "#{entry.fetch("term")} = #{entry.fetch("meaning")}"
              entry.fetch("topic") == "unknown" ? rendered : "#{rendered} → #{entry.fetch("topic")}"
            end
            "Local words (any script, with or without diacritics, inflected forms included): #{entries.join("; ")}. " \
              "conversation.lexicon_topics lists the topics whose local words appear in the message; " \
              "they are hints, the whole message decides."
          end

          def normalize_lexicon(value)
            raise Contracts::Invalid, "Lexicon must be a list" unless value.is_a?(Array)
            raise Contracts::Invalid, "Lexicon too large" if value.size > MAX_LEXICON_ENTRIES

            entries = value.map { |entry| normalize_lexicon_entry(entry) }
            folded = entries.map { |entry| entry.fetch("folded") }
            raise Contracts::Invalid, "Duplicate lexicon term" unless folded.uniq.size == folded.size

            entries.freeze
          end

          def normalize_lexicon_entry(value)
            entry = Contracts.object!(value, %w(term meaning topic))
            raise Contracts::Invalid, "Incomplete lexicon entry" unless entry.size == 3

            term = Contracts.text!(entry.fetch("term"), limit: MAX_LEXICON_TERM_LENGTH)
            folded = Text.fold(term)
            raise Contracts::Invalid, "Lexicon term must contain letters or digits" if folded.empty?

            {
              "term" => term,
              "meaning" => Contracts.text!(entry.fetch("meaning"), limit: MAX_LEXICON_MEANING_LENGTH),
              "topic" => Contracts.enum!(entry.fetch("topic"), Contracts::TOPICS),
              "folded" => folded,
              "pattern" => lexicon_pattern(folded)
            }.freeze
          end

          # Each folded word may carry a Serbian ending; the bare word or its
          # stem (the word minus a final vowel) must still be present whole.
          def lexicon_pattern(folded)
            words = folded.split.map do |word|
              stem = word.match?(/[aeiou]\z/) && word.length > LEXICON_STEM_MIN_LENGTH ? word[0...-1] : word
              "(?:#{Regexp.escape(word)}|#{Regexp.escape(stem)})(?:#{LEXICON_ENDINGS})?"
            end
            /\b#{words.join(" ")}\b/
          end

          def message_text(message)
            value = message.is_a?(String) ? message : message.respond_to?(:text) && message.text
            Contracts.text!(value, limit: Contracts::MAX_MESSAGE_LENGTH).tap do |text|
              raise Contracts::Invalid, "Empty citizen message" if text.strip.empty?
            end
          end

          def configured?
            @client.respond_to?(:configured?) && @client.configured?
          rescue StandardError
            false
          end

          def provider_budget(deadline)
            return unless deadline.respond_to?(:deadline) && deadline.respond_to?(:remaining_seconds)
            return unless deadline.respond_to?(:expired?) && deadline.respond_to?(:within)

            maximum = [@configuration.fetch("max_understanding_seconds"), MAX_PROVIDER_SECONDS].min
            deadline.within(maximum)
          end

          def with_timeout(budget, &)
            seconds = Float(budget.remaining_seconds)
            raise ProviderUnavailable, "budget" unless seconds.finite? && seconds.positive?

            value = Timeout.timeout(seconds, ProviderTimeout, &)
            raise ProviderTimeout, "Provider deadline expired" if budget.expired?

            value
          end

          def prompt_contents(text:, projection:, history:, state:)
            bounded_history(history, state).flat_map do |turn|
              [
                { role: "user", parts: [{ text: turn.fetch("user") }] },
                { role: "model", parts: [{ text: turn.fetch("bot") }] }
              ]
            end + [{
              role: "user",
              parts: [{ text: JSON.generate({ "conversation" => projection, "message" => text }) }]
            }]
          end

          def bounded_history(history, state)
            return [] unless history.is_a?(Array)

            history.last(@configuration.fetch("max_history_turns")).filter_map { |turn| history_turn(turn, state) }
          end

          def history_turn(turn, state)
            return unless turn.is_a?(Hash)

            values = turn.transform_keys(&:to_s)
            return unless values.has_key?("at") && valid_history_time?(values.fetch("at"))

            user = Contracts.text!(values.fetch("user"), limit: @configuration.fetch("max_history_text_length"))
            bot = Contracts.text!(values.fetch("bot"), limit: @configuration.fetch("max_history_text_length"))
            return if secret_like?(user, state) || secret_like?(bot, state)

            { "user" => user, "bot" => bot }
          rescue KeyError, Contracts::Invalid
            nil
          end

          def valid_history_time?(value)
            timestamp = case value
                        when Time
                          value
                        when String
                          Time.iso8601(value)
                        when Numeric
                          epoch = value.to_f
                          return false unless epoch.finite? && epoch.positive?

                          Time.at(epoch).utc
                        end
            now = @wall_clock.call
            return false unless timestamp.is_a?(Time) && now.is_a?(Time)

            (0...Contracts::CONTEXT_TTL).cover?(now - timestamp)
          rescue ArgumentError, TypeError, RangeError
            false
          end

          # lexicon_topics is bounded by the lexicon itself (at most one entry
          # per distinct topic) and, like suspended_task, is only present when
          # there is something to say.
          def state_projection(state, locale:, lexicon_topics: EMPTY_HINTS)
            projection = if state.nil? || state == {}
                           { "active_task" => nil, "topic" => "unknown", "pending_slot" => nil, "entities" => {}, "locale" => locale }
                         else
                           conversation_projection(state, locale:)
                         end
            projection["lexicon_topics"] = lexicon_topics unless lexicon_topics.empty?
            projection
          end

          def conversation_projection(state, locale:)
            raise Contracts::Invalid, "Invalid conversation state" unless state.is_a?(Hash)

            values = stringify_unique_keys(state)
            projection = {
              "active_task" => optional_enum(values["active_task"], Contracts::ACTIONS),
              "topic" => optional_enum(values["topic"], Contracts::TOPICS) || "unknown",
              "pending_slot" => optional_enum(values["pending_slot"], Contracts::ENTITY_KEYS),
              "entities" => bounded_entities(values.fetch("entities", {}), state),
              "locale" => locale
            }
            suspended = values["suspended_task"]
            projection["suspended_task"] = suspended_projection(suspended, locale:, state:) unless suspended.nil?
            projection
          end

          def suspended_projection(value, locale:, state:)
            raise Contracts::Invalid, "Invalid suspended task" unless value.is_a?(Hash)

            values = stringify_unique_keys(value)
            {
              "active_task" => optional_enum(values["active_task"], Contracts::ACTIONS),
              "topic" => optional_enum(values["topic"], Contracts::TOPICS) || "unknown",
              "pending_slot" => optional_enum(values["pending_slot"], Contracts::ENTITY_KEYS),
              "entities" => bounded_entities(values.fetch("entities", {}), state),
              "locale" => Contracts::LOCALES.include?(values["locale"]) ? values["locale"] : locale
            }
          end

          def bounded_entities(value, state)
            raise Contracts::Invalid, "Invalid conversation entities" unless value.is_a?(Hash)

            stringify_unique_keys(value).to_h do |key, item|
              raise Contracts::Invalid, "Unsupported conversation entity" unless Contracts::ENTITY_KEYS.include?(key)

              limit = key == "description" ? 1000 : 160
              text = Contracts.text!(item, limit:)
              raise Contracts::Invalid, "Credential in conversation entity" if secret_like?(text, state)

              [key, text]
            end
          end

          def stringify_unique_keys(value)
            normalized = value.transform_keys(&:to_s)
            raise Contracts::Invalid, "Duplicate conversation keys" unless normalized.size == value.size

            normalized
          end

          def optional_enum(value, allowed)
            return if value.nil?

            Contracts.enum!(value, allowed)
          end

          LATIN_LOCALES = %w(sr bs hr en).freeze
          CLEAR_SCRIPT_MIN_LETTERS = 3

          # The current message's script wins when it is clear; otherwise the
          # saved locale does; with nothing saved, the plain script ratio.
          def locale_for(state, text)
            saved = saved_locale(state)
            case clear_script(text)
            when :cyrillic then "sr-Cyrl"
            when :latin then LATIN_LOCALES.include?(saved) ? saved : "sr"
            else saved || ratio_locale(text)
            end
          end

          def saved_locale(state)
            value = state["locale"] || state[:locale] if state.is_a?(Hash)
            value if Contracts::LOCALES.include?(value)
          end

          # A mostly Cyrillic message is clear on its own. A Latin message is
          # clear only with at least two words: a lone place name or number is
          # typed in Latin by Cyrillic writers too and must not flip the reply.
          def clear_script(text)
            words = text.to_s.scan(/\p{L}+/)
            letters = words.sum(&:length)
            return if letters < CLEAR_SCRIPT_MIN_LETTERS

            cyrillic = text.to_s.scan(/\p{Cyrillic}/).size
            return :cyrillic if cyrillic.fdiv(letters) >= 0.5

            :latin if cyrillic.zero? && words.size >= 2
          end

          def ratio_locale(text)
            cyrillic = text.to_s.scan(/\p{Cyrillic}/).size
            letters = text.to_s.scan(/\p{L}/).size
            letters.positive? && cyrillic.fdiv(letters) >= 0.5 ? "sr-Cyrl" : "sr"
          end

          def cancellation?(message, text)
            (message.respond_to?(:cancel?) && message.cancel?) || CANCEL_PHRASES.include?(Text.fold(text))
          end

          def cancellation(locale:, state:)
            topic = state["topic"] || state[:topic] if state.is_a?(Hash)
            topic = "unknown" unless Contracts::TOPICS.include?(topic)
            payload = {
              "action" => "cancel", "topic" => topic, "entities" => {},
              "operation" => "cancel", "needs_clarification" => false,
              "secondary" => nil, "locale" => locale
            }
            Contracts::Understanding.parse(payload)
          end

          def bypass_model?(message, text, state)
            [:credential_handled?, :trusted_button?, :safety_signal?].any? do |predicate|
              message.respond_to?(predicate) && message.public_send(predicate)
            end || secret_like?(text, state)
          end

          # Credential-labelled text (kod/code/otp/lozinka/token, verify links)
          # is always a secret. Bare digits and phone-shaped numbers are one
          # only while the conversation waits for a code, reference or phone;
          # otherwise a house number, a meter reading or "123456" typed during
          # a waste question reaches the model. The state store's own guard
          # still keeps such numbers out of stored history and entities.
          def secret_like?(text, state)
            value = text.to_s.strip
            return false if value.empty? || value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
            return true if awaiting_secret?(state) && phone_or_code_shaped?(value)
            return true if value.match?(/(?:\A|[^\p{L}])(?:kod|code|otp|код)\s*(?::|=|je|is|је)?\s*\d{4,8}(?!\d)/iu)
            return true if value.match?(/(?:lozinka|password|šifra|sifra|лозинка|шифра)\s+(?:je|is|је)\s+\S+/iu)
            return true if value.match?(%r{(?:\bverify_|/v/)[A-Za-z0-9_-]{8,}|[?&](?:token|code|password|api_key)=}i)

            value.match?(/(?:\b(?:password|lozinka|šifra|sifra|otp|token|kod)|лозинка|шифра|код)\s*[:=]\s*\S+/i)
          end

          def phone_or_code_shaped?(value)
            value.match?(/\A\d{6}\z/) ||
              value.match?(%r{\A(?:\+|0)[\d\s()./-]{7,25}\z}) ||
              value.match?(/(?<!\w)\+\d[\d\s().-]{6,24}\d(?!\d)/)
          end

          def awaiting_secret?(state)
            return false unless state.is_a?(Hash)

            AWAITING_SECRET_SLOTS.include?(state["pending_slot"] || state[:pending_slot]) ||
              AWAITING_SECRET_TASKS.include?(state["active_task"] || state[:active_task])
          end

          def positive_number!(value)
            number = Float(value)
            raise Contracts::Invalid, "Understanding timeout must be positive" unless number.finite? && number.positive?

            number
          rescue TypeError, ArgumentError
            raise Contracts::Invalid, "Understanding timeout must be positive"
          end

          def bounded_integer!(value, maximum:)
            number = Integer(value)
            raise Contracts::Invalid, "Understanding bound is invalid" unless number.positive? && number <= maximum

            number
          rescue TypeError, ArgumentError
            raise Contracts::Invalid, "Understanding bound is invalid"
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "digest"
require "json"
require "redis"
require "decidim/bih/redis_endpoint"
require_relative "contracts"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A short-lived memo in front of the understanding model call. A hit
        # replaces exactly one provider request and nothing else: the cached
        # value is the model's own parsed classification, which stays advisory
        # data — it grants no authority, confirms no write and is never reused
        # as an authorization.
        #
        # The key is scoped to tenant and actor, the folded citizen text, the
        # state projection the model would receive, the contract version, the
        # prompt fingerprint and the locale. History is deliberately not part
        # of it: its raw text never leaves the turn. A turn with a report in
        # progress, a message too short to classify stably, and a
        # clarification are never cached. Any storage failure is a miss.
        #
        # Off unless MILICA_UNDERSTANDING_CACHE is set: a disabled cache never
        # opens a Redis connection.
        class UnderstandingCache
          KEY_PREFIX = "decidim:bih:concierge:understanding:v1"
          TTL_SECONDS = 600
          ENVIRONMENT_FLAG = "MILICA_UNDERSTANDING_CACHE"
          ENABLED_VALUES = %w(1 true).freeze
          MIN_LETTERS = 3
          # An Understanding is a handful of enums plus bounded entities; a
          # larger stored value is corrupt, not a bigger answer.
          MAX_VALUE_BYTES = 8_000
          REDIS_TIMEOUT = 0.2

          def self.from_environment(env: ENV, redis: nil, logger: nil)
            value = env.fetch(ENVIRONMENT_FLAG, "").to_s.strip.downcase
            new(enabled: ENABLED_VALUES.include?(value), redis:, logger:)
          end

          def initialize(enabled: true, redis: nil, logger: nil)
            @enabled = enabled == true
            @redis = redis
            @logger = logger
          end

          def enabled? = @enabled

          # The storage key for this turn, or nil when the turn must not touch
          # the cache at all: disabled, no trusted scope (fail closed), a
          # report draft or handoff pending, or too few letters to classify.
          def key_for(scope:, text:, projection:, prompt_fingerprint:, locale:, state:) # rubocop:disable Metrics/ParameterLists
            return unless enabled? && scope.is_a?(Contracts::TrustedContext)
            return if report_in_progress?(state) || text.to_s.scan(/\p{L}/).size < MIN_LETTERS

            material = JSON.generate([
                                       scope.organization_id, actor_scope(scope.actor_id), Text.fold(text), projection,
                                       Contracts::VERSION, prompt_fingerprint, locale
                                     ])
            "#{KEY_PREFIX}:#{scope.organization_id}:#{Digest::SHA256.hexdigest(material)}"
          end

          # The cached Understanding, or nil on a miss. A clarification, a
          # corrupt or oversized value and every storage error are misses.
          def read(key)
            raw = redis.get(key)
            return if raw.nil?
            return unless raw.is_a?(String) && raw.bytesize <= MAX_VALUE_BYTES

            parsed = Contracts::Understanding.parse(JSON.parse(raw))
            return if parsed.needs_clarification

            log("[MilicaUnderstandCache] hit", level: :debug)
            parsed
          rescue StandardError => e
            record_failure(e)
            nil
          end

          # Stores a successful classification for TTL_SECONDS. Clarifications
          # are not answers and are never written.
          def write(key, understanding)
            return false unless understanding.is_a?(Contracts::Understanding) && !understanding.needs_clarification

            redis.set(key, JSON.generate(understanding.to_h), ex: TTL_SECONDS)
            true
          rescue StandardError => e
            record_failure(e)
            false
          end

          private

          def actor_scope(actor_id)
            "actor:#{actor_id || "anonymous"}"
          end

          def report_in_progress?(state)
            return false unless state.is_a?(Hash)

            !(state["draft"] || state[:draft]).nil? || (state["report_handoff_offered"] || state[:report_handoff_offered]) == true
          end

          # Same construction as StateStore: short timeouts, no reconnects, so
          # a slow Redis costs a bounded moment and never the turn.
          def redis
            @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url,
                                 connect_timeout: REDIS_TIMEOUT, read_timeout: REDIS_TIMEOUT, write_timeout: REDIS_TIMEOUT, reconnect_attempts: 0)
          end

          # Class name only: a storage error may quote the connection URL.
          def record_failure(error)
            log("[MilicaUnderstandCache] miss error=#{error.class.name}", level: :warn)
          end

          def log(line, level:)
            logger&.public_send(level, line)
            nil
          rescue StandardError
            nil
          end

          def logger
            return @logger unless @logger.nil?

            Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
          end
        end
      end
    end
  end
end

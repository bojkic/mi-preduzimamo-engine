# frozen_string_literal: true

require "redis"
require "securerandom"
require "timeout"
require "decidim/bih/config"
require "decidim/bih/redis_endpoint"
require_relative "turn_budget"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Deployment-wide cap for slow conversation turns. Redis owns the
        # atomic lease set, so separate Puma workers observe the same limit.
        # Store failure denies admission instead of opening unbounded provider
        # work. Every lease has an expiry and can only be released by its token.
        # The limit comes from MILICA_ADMISSION_LIMIT (Config.admission_limit)
        # and can never exceed MAX_LIMIT, whatever the environment says.
        class AdmissionControl
          DEFAULT_KEY = "decidim:bih:concierge:slow_turns:v1"
          MAX_LIMIT = Decidim::Bih::Config::ADMISSION_LIMIT_MAXIMUM
          DEFAULT_LEASE_TTL = 12.0
          DEFAULT_REDIS_TIMEOUT = 0.5
          DEFAULT_MAX_WORK_SECONDS = TurnBudget::MAX_TIMEOUT

          ACQUIRE_SCRIPT = <<~LUA
            local key = KEYS[1]
            local now = tonumber(ARGV[1])
            local expires_at = tonumber(ARGV[2])
            local limit = tonumber(ARGV[3])
            local token = ARGV[4]
            redis.call("ZREMRANGEBYSCORE", key, "-inf", now)
            if redis.call("ZCARD", key) >= limit then
              return 0
            end
            redis.call("ZADD", key, expires_at, token)
            local latest = redis.call("ZRANGE", key, -1, -1, "WITHSCORES")
            if latest[2] then
              local ttl_ms = math.max(1, math.ceil((tonumber(latest[2]) - now) * 1000))
              redis.call("PEXPIRE", key, ttl_ms)
            end
            return 1
          LUA

          RELEASE_SCRIPT = <<~LUA
            local removed = redis.call("ZREM", KEYS[1], ARGV[1])
            if redis.call("ZCARD", KEYS[1]) == 0 then
              redis.call("DEL", KEYS[1])
            end
            return removed
          LUA

          Result = Data.define(:status, :value, :phase, :reason, :failure_site) do
            STATUSES = [:admitted, :capacity, :unavailable, :expired].freeze
            PHASES = [:pre_admission, :admission_store, :capacity, :work_setup, :work_execution, :runtime].freeze
            REASONS = %w(
              contract_text contract_provenance contract_enum contract_field
              contract_clarification contract_draft contract_draft_reference
              contract_report_handoff contract_invalid internal_error
            ).freeze
            FAILURE_SITE = /\A[a-z0-9_]+:[1-9]\d{0,5}:[a-zA-Z0-9_?!]+\z/

            # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- each result field is validated against its closed vocabulary
            def initialize(status:, value: nil, phase: nil, reason: nil, failure_site: nil)
              raise ArgumentError, "Unknown admission status" unless STATUSES.include?(status)
              raise ArgumentError, "Unknown admission phase" if phase && !PHASES.include?(phase) # rubocop:disable Rails/NegateInclude -- loaded without ActiveSupport in the plain suite
              raise ArgumentError, "Unknown admission reason" if reason && !REASONS.include?(reason) # rubocop:disable Rails/NegateInclude -- loaded without ActiveSupport in the plain suite
              raise ArgumentError, "Invalid failure site" if failure_site && !FAILURE_SITE.match?(failure_site)
              raise ArgumentError, "Failure details require runtime phase" if (reason || failure_site) && phase != :runtime

              super
            end
            # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

            def admitted? = status == :admitted
          end

          class RedisOperationTimeout < Timeout::Error; end

          class WorkTimeout < Timeout::Error; end

          # Explicit injection keeps the global lease testable without touching
          # a real Redis service or process clock.
          # rubocop:disable Metrics/ParameterLists
          def initialize(redis: nil, key: DEFAULT_KEY, limit: Decidim::Bih::Config.admission_limit, lease_ttl: DEFAULT_LEASE_TTL,
                         redis_timeout: DEFAULT_REDIS_TIMEOUT, max_work_seconds: DEFAULT_MAX_WORK_SECONDS,
                         clock: nil, token_factory: nil)
            @redis = redis
            @key = valid_key!(key)
            @limit = positive_integer!(limit, "limit")
            raise ArgumentError, "limit exceeds deployment maximum" if @limit > MAX_LIMIT

            @lease_ttl = positive_number!(lease_ttl, "lease_ttl")
            @redis_timeout = positive_number!(redis_timeout, "redis_timeout")
            @max_work_seconds = positive_number!(max_work_seconds, "max_work_seconds")
            raise ArgumentError, "max_work_seconds exceeds turn maximum" if @max_work_seconds > TurnBudget::MAX_TIMEOUT

            @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @token_factory = token_factory || -> { SecureRandom.hex(24) }
          end
          # rubocop:enable Metrics/ParameterLists

          def with_slot(deadline:)
            token = nil
            begin
              remaining = remaining_time(deadline)
              return Result.new(status: :expired, phase: :pre_admission) if remaining <= 0.0 || deadline.expired?

              token = lease_token!
              lease_expires_at = bounded_redis(deadline) { acquire(token:) }
            rescue StandardError
              release(token, deadline:) if token
              return Result.new(status: :unavailable, phase: :admission_store)
            end

            return Result.new(status: :capacity, phase: :capacity) unless lease_expires_at

            execute_admitted(token:, deadline:, lease_expires_at:) { yield }
          end

          private

          def acquire(token:)
            now = monotonic_now
            expires_at = now + @lease_ttl
            admitted = redis.eval(
              ACQUIRE_SCRIPT,
              keys: [@key],
              argv: [now, expires_at, @limit, token]
            ).to_i == 1
            admitted ? expires_at : false
          end

          def execute_admitted(token:, deadline:, lease_expires_at:)
            begin
              work_seconds = allowed_work_seconds(deadline, lease_expires_at:)
              return Result.new(status: :expired, phase: :work_setup) unless work_seconds.positive?

              work_budget = deadline.within(work_seconds)
              seconds = [Float(work_budget.remaining_seconds), work_seconds].min
              return Result.new(status: :expired, phase: :work_setup) unless seconds.finite? && seconds.positive?
            rescue StandardError
              return Result.new(status: :unavailable, phase: :work_setup)
            end

            value = Timeout.timeout(seconds, WorkTimeout) { yield }
            # WorkTimeout is intentionally a normal, narrowly rescued exception,
            # so admitted application code can catch it. Reject any value returned
            # after the derived max-work/lease/turn bound; this does not claim the
            # interrupt forcibly stopped code that chose to suppress it.
            return Result.new(status: :expired, phase: :work_execution) if work_budget.expired?

            Result.new(status: :admitted, value:)
          rescue WorkTimeout
            Result.new(status: :expired, phase: :work_execution)
          ensure
            release(token, deadline:)
          end

          def allowed_work_seconds(deadline, lease_expires_at:)
            remaining = remaining_time(deadline)
            lease_remaining = lease_expires_at - monotonic_now
            [@max_work_seconds, remaining - @redis_timeout, lease_remaining - @redis_timeout].min
          end

          def bounded_redis(deadline, &)
            seconds = [remaining_time(deadline), @redis_timeout].min
            raise RedisOperationTimeout, "Redis deadline expired" unless seconds.positive?

            Timeout.timeout(seconds, RedisOperationTimeout, &)
          end

          def release(token, deadline:)
            bounded_redis(deadline) do
              redis.eval(RELEASE_SCRIPT, keys: [@key], argv: [token])
            end
          rescue StandardError
            # The lease score still expires and is pruned by the next acquire.
            nil
          end

          def remaining_time(deadline)
            unless deadline.respond_to?(:remaining_seconds) && deadline.respond_to?(:expired?) &&
                   deadline.respond_to?(:deadline) && deadline.respond_to?(:within)
              raise ArgumentError, "TurnBudget deadline required"
            end

            remaining = Float(deadline.remaining_seconds)
            raise ArgumentError, "Invalid remaining deadline" unless remaining.finite?

            remaining
          end

          def monotonic_now
            value = Float(@clock.call)
            raise ArgumentError, "Invalid monotonic clock" unless value.finite?

            value
          end

          def lease_token!
            token = @token_factory.call.to_s
            raise ArgumentError, "Invalid lease token" unless token.match?(/\A[a-zA-Z0-9_-]{16,128}\z/)

            token
          end

          def valid_key!(key)
            value = key.to_s
            raise ArgumentError, "Invalid admission key" if value.empty? || value.bytesize > 200

            value.freeze
          end

          def positive_integer!(value, name)
            number = Integer(value)
            raise ArgumentError, "#{name} must be positive" unless number.positive?

            number
          rescue TypeError, ArgumentError
            raise ArgumentError, "#{name} must be positive"
          end

          def positive_number!(value, name)
            number = Float(value)
            raise ArgumentError, "#{name} must be finite and positive" unless number.finite? && number.positive?

            number
          rescue TypeError, ArgumentError
            raise ArgumentError, "#{name} must be finite and positive"
          end

          def redis
            @redis ||= Redis.new(
              url: Decidim::Bih::RedisEndpoint.url,
              connect_timeout: @redis_timeout,
              read_timeout: @redis_timeout,
              write_timeout: @redis_timeout
            )
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "openssl"
require "decidim/bih/redis_endpoint"

module Decidim
  module Bih
    module PhoneVerification
      # Server-side counter of wrong codes per verification challenge (spec
      # 5.4.2). Decidim's own ConfirmUserAuthorization only sleeps and counts
      # in the session, so it protects nothing across sessions or IPs. The key
      # is an HMAC of organization + authorization + challenge version, and no
      # raw id ever reaches Redis. The challenge version is the authorization's
      # created_at, NOT the current code: a resend deliberately does NOT start
      # a fresh counter, because that would hand a free set of guesses to
      # anyone who presses "send again" — which is the whole attack. Only
      # changing the number, which destroys the row, legitimately starts over.
      # Redis trouble counts as exhausted: the link path still works, the code
      # path closes.
      class AttemptLimiter
        MAX_ATTEMPTS = 5
        # One budget per code lifetime: the code lives LoginToken::VERIFY_TTL,
        # so the counter must too, or every ten minutes would hand out five
        # more guesses. A literal rather than a reference because this file is
        # unit-tested without the model loaded; login_token_test pins the two.
        TTL_SECONDS = 24.hours.to_i
        KEY_PREFIX = "decidim-bih:phone-verification:attempts:"
        HMAC_KEY_FALLBACK = "decidim-bih-attempt-limiter"

        # INCR and EXPIRE as two round-trips can lose the race: a crash or
        # dropped connection between them leaves a counted key with no TTL,
        # which never expires and permanently locks that challenge. Doing
        # both inside one Lua script (as Viber::OtpStore already does) makes
        # "increment, and set the TTL only on the first increment" atomic.
        INCREMENT_COUNTER_SCRIPT = <<~LUA
          local value = redis.call("INCR", KEYS[1])
          if value == 1 then redis.call("EXPIRE", KEYS[1], ARGV[1]) end
          return value
        LUA

        def initialize(organization_id:, authorization_id:, challenge_version:, redis: nil)
          @redis = redis
          @store_error = false
          @key = key_prefix + OpenSSL::HMAC.hexdigest(
            "SHA256",
            hmac_secret,
            [organization_id, authorization_id, challenge_version].join("\0")
          )
        end

        def exhausted?
          redis.get(@key).to_i >= limit
        rescue StandardError
          @store_error = true
          true
        end

        def record_failure!
          redis.eval(INCREMENT_COUNTER_SCRIPT, keys: [@key], argv: [ttl_seconds])
        rescue StandardError
          @store_error = true
          limit
        end

        def reset!
          redis.del(@key)
        rescue StandardError
          @store_error = true
          nil
        end

        # True when the counter could not be read or written at all, as opposed
        # to genuinely standing at the limit. Both close the code path — the
        # limiter stays fail-closed — but only one of them may be reported to
        # the citizen as "too many wrong attempts"; the other is our outage,
        # and someone with zero attempts must not be blamed for it.
        def store_error? = @store_error

        # Seconds until the counter expires, or nil when that cannot be known
        # (no key, no TTL, or an unreachable store). Read-only: it never
        # creates a key and never changes one. Callers render "try again at…"
        # from it, and a nil must stay "we do not know" rather than becoming a
        # confident zero that invites an immediate retry.
        def retry_after_seconds
          remaining = redis.ttl(@key)
          return nil unless remaining.is_a?(Integer) && remaining.positive?

          remaining
        rescue StandardError
          @store_error = true
          nil
        end

        private

        # The three knobs a sibling counter over the same (organization,
        # authorization, challenge) triple overrides: its own key namespace
        # and its own numbers. Methods rather than constants because a
        # constant referenced inside this class resolves here whatever the
        # subclass declares — see ResendBudget, which counts paid messages
        # instead of wrong codes.
        def key_prefix = KEY_PREFIX

        def limit = MAX_ATTEMPTS

        def ttl_seconds = TTL_SECONDS

        def hmac_secret
          if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
            Rails.application.secret_key_base
          else
            HMAC_KEY_FALLBACK
          end
        end

        def redis
          @redis ||= begin
            require "redis"
            ::Redis.new(url: Decidim::Bih::RedisEndpoint.url)
          end
        end
      end
    end
  end
end

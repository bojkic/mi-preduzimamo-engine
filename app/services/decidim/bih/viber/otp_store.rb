# frozen_string_literal: true

require "redis"
require "openssl"
require "active_support/key_generator"
require "active_support/message_encryptor"
require "decidim/bih/redis_endpoint"
require_relative "../durable_effects"

module Decidim
  module Bih
    module Viber
      # Redis-backed scratch storage for the per-sender OTP verification flow.
      #
      # Nothing here is persisted to the database: a pending OTP is short-lived,
      # security-sensitive state, so it lives in Redis under a TTL and evaporates
      # on expiry. We store ONLY a salted digest of the code (never the plaintext
      # 6 digits) together with the target phone and an attempt counter. Pending
      # values are encrypted and key suffixes are purpose-separated HMACs, so raw
      # senders and phones never appear in Redis key listings or values.
      #
      # Four key families, all namespaced under "bih:viber:" and ending in an
      # opaque HMAC rather than a raw citizen identifier:
      #   bih:viber:otp:<org>:<hmac>         -> encrypted pending OTP (<=10 min)
      #   bih:viber:otpattempts:<org>:<hmac> -> wrong-code attempts (<=10 min)
      #   bih:viber:send:<org>:<hmac>        -> sender send counter (15 min)
      #   bih:viber:sendto:<org>:<hmac>      -> destination send counter (15 min)
      #
      # Keys are scoped by organization so the same Viber id under two tenants
      # never collides. The Redis connection is injectable so tests can pass a
      # fake or a throwaway namespace; by default we build one from REDIS_URL
      # (falling back to the conventional local URL, mirroring rack_attack).
      class OtpStore
        KEY_PREFIX = "bih:viber"
        DEFAULT_TTL = 10 * 60 # pending OTP lifetime: 10 minutes
        SEND_WINDOW = 15 * 60 # rolling window for the send-rate limit
        SEND_MAX = 3 # max OTP sends per SENDER per window
        SEND_TO_MAX = 3 # max OTP sends to a destination PHONE per window
        HMAC_KEY_SALT = "decidim-bih-viber-otp-redis-keys"
        ENCRYPTION_KEY_SALT = "decidim-bih-viber-otp-pending-value"
        ENCRYPTION_PURPOSE = "decidim-bih-viber-otp"
        PUT_SCRIPT = <<~LUA
          local result = redis.call("SET", KEYS[1], ARGV[1], "EX", ARGV[2])
          if result then redis.call("DEL", KEYS[2]) end
          return result
        LUA
        INCREMENT_COUNTER_SCRIPT = <<~LUA
          local value = redis.call("INCR", KEYS[1])
          if value == 1 then redis.call("EXPIRE", KEYS[1], ARGV[1]) end
          return value
        LUA
        ROLLBACK_COUNTER_SCRIPT = <<~LUA
          local current = redis.call("GET", KEYS[1])
          if not current then return 0 end
          local value = redis.call("DECR", KEYS[1])
          if value <= 0 then
            redis.call("DEL", KEYS[1])
            return 0
          end
          return value
        LUA

        def initialize(redis: nil, organization_id: nil, hmac_key: nil, encryptor: nil)
          @redis = redis
          @organization_id = organization_id
          @hmac_key = hmac_key
          @encryptor = encryptor
        end

        # Returns a copy bound to a specific organization (used by AccountLinking
        # so callers don't have to thread the org id through every call).
        def for_organization(organization_id)
          self.class.new(redis: redis, organization_id: organization_id, hmac_key:, encryptor:)
        end

        # Stores a fresh pending OTP for +sender+, overwriting any previous one and
        # resetting the attempt counter. +digest+ is the HMAC of the code; the
        # plaintext is never given to this store.
        def put(sender:, phone:, digest:, ttl: DEFAULT_TTL)
          payload = dump(phone: phone, digest: digest, created_at: Time.now.to_i)
          Decidim::Bih::DurableEffects.redis_eval(
            redis:,
            script_id: "viber_otp_put_v1",
            keys: [otp_key(sender), attempts_key(sender)],
            argv: [payload, bounded_ttl(ttl)]
          )
        end

        # Returns the pending OTP as a symbol-keyed Hash
        # ({ phone:, digest:, attempts:, created_at: }) or nil when none/expired.
        def get(sender:)
          raw = redis.get(otp_key(sender))
          return nil if raw.nil?

          load(raw)
        end

        # Bumps the attempt counter ATOMICALLY (Redis INCR) so concurrent webhook
        # deliveries can't both read the same value and bypass the limit. Returns
        # the new count, or nil when there is no pending OTP.
        def increment_attempts(sender:)
          return nil if redis.get(otp_key(sender)).nil?

          key = attempts_key(sender)
          increment_window_counter(key, ttl: DEFAULT_TTL)
        end

        # Drops the pending OTP for +sender+ (on success or after the attempt limit).
        def clear(sender:)
          Decidim::Bih::DurableEffects.redis_delete(otp_key(sender), attempts_key(sender), redis:)
        end

        # Per-SENDER send-rate limiter (records this send). The window slides from
        # the first send.
        def allow_send?(sender:)
          allow?(send_key(sender), SEND_MAX)
        end

        # Per-DESTINATION-PHONE send-rate limiter. Critical: the sender is
        # attacker-controlled and unrelated to the number being verified, so
        # without this a single sender could SMS-bomb a victim's phone. Keyed by
        # phone, this caps total OTPs to any one number regardless of sender.
        def allow_send_to?(phone:)
          allow?(send_to_key(phone), SEND_TO_MAX)
        end

        private

        attr_reader :organization_id

        # Lazily build a Redis connection so merely constructing the store (e.g.
        # at boot) never opens a socket. The shared resolver fails closed under test.
        def redis
          @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url)
        end

        # Increment a windowed counter and report whether it is still within +max+.
        def allow?(key, max)
          increment_window_counter(key, ttl: SEND_WINDOW) <= max
        end

        # Rate-limit and wrong-code counters must be visible immediately so the
        # current handler can make its decision. When a durable receipt later
        # rolls back, compensate that INCR atomically; otherwise a failed OTP
        # send or retried wrong-code message could consume a citizen's budget.
        def increment_window_counter(key, ttl:)
          transaction = active_transaction
          count = redis.eval(INCREMENT_COUNTER_SCRIPT, keys: [key], argv: [ttl])
          transaction&.after_rollback { rollback_counter(key) }
          count
        rescue StandardError
          rollback_counter(key) if transaction && count
          raise
        end

        def rollback_counter(key)
          redis.eval(ROLLBACK_COUNTER_SCRIPT, keys: [key])
        end

        def active_transaction
          return unless defined?(ActiveRecord::Base)

          pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(
            ActiveRecord::Base.connection_specification_name
          )
          return unless pool

          transaction = ActiveRecord::Base.current_transaction
          transaction if transaction.open?
        rescue ActiveRecord::ConnectionNotEstablished
          nil
        end

        def bounded_ttl(ttl)
          Integer(ttl).clamp(1, DEFAULT_TTL)
        rescue ArgumentError, TypeError
          DEFAULT_TTL
        end

        def otp_key(sender)
          redis_key("otp", sender)
        end

        def attempts_key(sender)
          redis_key("otpattempts", sender)
        end

        def send_key(sender)
          redis_key("send", sender)
        end

        def send_to_key(phone)
          redis_key("sendto", phone)
        end

        def dump(**hash)
          encryptor.encrypt_and_sign(JSON.generate(hash), purpose: ENCRYPTION_PURPOSE)
        end

        def load(raw)
          plaintext = encryptor.decrypt_and_verify(raw, purpose: ENCRYPTION_PURPOSE)
          JSON.parse(plaintext, symbolize_names: true)
        rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
          nil
        end

        def redis_key(family, identity)
          identity = identity.to_s
          raise ArgumentError, "Viber OTP identity is invalid" if identity.strip.empty? || identity.bytesize > 255

          digest = OpenSSL::HMAC.hexdigest("SHA256", hmac_key, [family, organization_id, identity].join("\0"))
          "#{KEY_PREFIX}:#{family}:#{organization_id}:#{digest}"
        end

        def hmac_key
          @hmac_key ||= key_generator.generate_key(HMAC_KEY_SALT, 32)
        end

        def encryptor
          @encryptor ||= ActiveSupport::MessageEncryptor.new(key_generator.generate_key(ENCRYPTION_KEY_SALT, 32))
        end

        def key_generator
          ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base.to_s)
        end
      end
    end
  end
end

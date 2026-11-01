# frozen_string_literal: true

require "redis"
require "openssl"
require "active_support/key_generator"
require "decidim/bih/redis_endpoint"
require_relative "../durable_effects"

module Decidim
  module Bih
    module Concierge
      # Tiny Redis-backed per-sender conversation state for the concierge bot.
      #
      # The bot is otherwise stateless/single-turn; the account-linking flow is the
      # first feature that needs to remember "what did I just ask this sender for".
      # We keep that as a single short string ("awaiting_phone" / "awaiting_code")
      # under a SHORT TTL so a half-finished or abandoned linking conversation
      # can never leave a sender permanently stuck — the state simply expires.
      #
      # Keys contain a keyed digest, never the raw Viber user id. They remain
      # organization-scoped so one provider identity cannot share state across
      # tenants.
      class SessionStore
        KEY_PREFIX = "bih:viber:state"
        DEFAULT_TTL = 10 * 60 # match the OTP lifetime so awaiting_code never expires first
        HMAC_KEY_SALT = "decidim-bih-viber-session-state"
        MAX_SENDER_BYTES = 255
        MAX_STATE_BYTES = 4096

        def initialize(redis: nil, organization_id: nil, hmac_key: nil)
          @redis = redis
          @organization_id = organization_id
          @hmac_key = hmac_key
        end

        # Returns a copy bound to a specific organization.
        def for_organization(organization_id)
          self.class.new(redis: redis, organization_id:, hmac_key: hmac_key)
        end

        # Current conversation state for +sender+, or nil when none/expired.
        def get(sender:)
          redis.get(key(sender))
        end

        # Sets the conversation state, refreshing the TTL on every turn so an
        # actively-progressing conversation never expires mid-flow.
        def set(sender:, state:, ttl: DEFAULT_TTL)
          Decidim::Bih::DurableEffects.redis_set(
            redis:,
            key: key(sender),
            value: bounded_state(state),
            ex: bounded_ttl(ttl)
          )
        end

        # Clears the state (on success/failure or to abandon the flow).
        def clear(sender:)
          Decidim::Bih::DurableEffects.redis_delete(key(sender), redis:)
        end

        private

        attr_reader :organization_id

        def redis
          @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url)
        end

        def key(sender)
          "#{KEY_PREFIX}:#{organization_id}:#{sender_digest(sender)}"
        end

        def sender_digest(sender)
          sender = sender.to_s
          raise ArgumentError, "Viber session sender is invalid" if sender.strip.empty? || sender.bytesize > MAX_SENDER_BYTES

          identity = ["viber", organization_id, sender].join("\0")
          OpenSSL::HMAC.hexdigest("SHA256", hmac_key, identity)
        end

        def hmac_key
          @hmac_key ||= ActiveSupport::KeyGenerator
                        .new(Rails.application.secret_key_base.to_s)
                        .generate_key(HMAC_KEY_SALT, 32)
        end

        def bounded_state(state)
          value = state.to_s
          raise ArgumentError, "Viber session state is blank" if value.strip.empty?

          return value if value.bytesize <= MAX_STATE_BYTES

          value.byteslice(0, MAX_STATE_BYTES).to_s.scrub("")
        end

        def bounded_ttl(ttl)
          Integer(ttl).clamp(1, DEFAULT_TTL)
        rescue ArgumentError, TypeError
          DEFAULT_TTL
        end
      end
    end
  end
end

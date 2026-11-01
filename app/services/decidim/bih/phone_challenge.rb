# frozen_string_literal: true

require "active_support/key_generator"
require "active_support/security_utils"
require "openssl"
require "redis"
require "decidim/bih/redis_endpoint"

module Decidim
  module Bih
    # Issues and checks the fresh login challenge used by returning citizens.
    #
    # A challenge has two presentations of one secret: the raw LoginToken in a
    # Viber/SMS link, and a six-digit code derived from that raw value with an
    # application-secret HMAC. The code is never stored. A successful code and
    # the link both claim the same LoginToken row, so only one can establish a
    # session. Registration keeps Decidim's existing verification code; after
    # that flow grants the authorization it uses CompletesPhoneAuthentication.
    class PhoneChallenge
      PURPOSE = "login"
      CODE_LENGTH = 6
      MAX_ATTEMPTS = 5
      CODE_KEY_SALT = "decidim-bih-phone-login-code"

      Challenge = Struct.new(:raw_token, :otp_code, :expires_at, keyword_init: true)

      class AttemptStore
        KEY_PREFIX = "bih:phone-login:attempts"
        KEY_SALT = "decidim-bih-phone-login-attempt-keys"
        INCREMENT_SCRIPT = <<~LUA
          local value = redis.call("INCR", KEYS[1])
          local current = redis.call("TTL", KEYS[1])
          local required = tonumber(ARGV[1])
          if current < required then redis.call("EXPIRE", KEYS[1], required) end
          return value
        LUA
        EXTEND_SCRIPT = <<~LUA
          local current = redis.call("TTL", KEYS[1])
          if current >= 0 and current < tonumber(ARGV[1]) then
            redis.call("EXPIRE", KEYS[1], ARGV[1])
          end
          return current
        LUA

        def initialize(redis: nil, hmac_key: nil)
          @redis = redis
          @hmac_key = hmac_key
        end

        def available!
          raise Redis::BaseError, "phone login challenge store is unavailable" unless redis.ping == "PONG"

          true
        end

        def record_attempt!(organization_id:, user_id:, purpose:, ttl:)
          redis.eval(
            INCREMENT_SCRIPT,
            keys: [key(organization_id:, user_id:, purpose:)],
            argv: [Integer(ttl).clamp(1, LoginToken::LOGIN_TTL.to_i)]
          ).to_i
        end

        # A resend extends an existing counter through the new challenge's
        # absolute expiry without changing its value. Attempts never extend it.
        def extend_expiry!(organization_id:, user_id:, purpose:, ttl:)
          redis.eval(
            EXTEND_SCRIPT,
            keys: [key(organization_id:, user_id:, purpose:)],
            argv: [Integer(ttl).clamp(1, LoginToken::LOGIN_TTL.to_i)]
          ).to_i
        end

        private

        def redis
          @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url)
        end

        def key(organization_id:, user_id:, purpose:)
          identity = [organization_id, user_id, purpose].join("\0")
          digest = OpenSSL::HMAC.hexdigest("SHA256", hmac_key, identity)
          "#{KEY_PREFIX}:#{digest}"
        end

        def hmac_key
          @hmac_key ||= key_generator.generate_key(KEY_SALT, 32)
        end

        def key_generator
          secret = Rails.application.secret_key_base.to_s
          raise ArgumentError, "secret_key_base is required for phone login challenges" if secret.empty?

          ActiveSupport::KeyGenerator.new(secret)
        end
      end

      class << self
        def issue!(...) = new.issue!(...)

        def verify_code(...) = new.verify_code(...)

        def consume!(...) = new.consume!(...)
      end

      def initialize(token_model: LoginToken, attempt_store: AttemptStore.new, code_key: nil, clock: -> { Time.current })
        @token_model = token_model
        @attempt_store = attempt_store
        @code_key = code_key
        @clock = clock
      end

      # A resend invalidates the prior LoginToken through LoginToken.issue!, but
      # deliberately does not clear the user-scoped attempt key. Switching
      # delivery channel or requesting another message cannot reset guessing.
      def issue!(user:, phone:)
        normalized_phone = phone.to_s.gsub(/[^+0-9]/, "")
        raise ArgumentError, "phone is required" if normalized_phone.empty?

        attempt_store.available! # Redis is part of the proof boundary: fail closed.
        expires_at = clock.call + token_model.ttl_for(PURPOSE)
        attempt_store.extend_expiry!(
          organization_id: user.organization.id,
          user_id: user.id,
          purpose: PURPOSE,
          ttl: (expires_at - clock.call).ceil
        )
        raw_token = token_model.issue!(user:, purpose: PURPOSE, phone: normalized_phone)
        Challenge.new(
          raw_token:,
          otp_code: code_for(raw_token),
          expires_at:
        )
      end

      # Returns the still-unconsumed LoginToken when the code is correct. The
      # caller must complete its grant checks and then call #consume! before
      # signing in. Every submitted value, including malformed input, consumes
      # one attempt. A fifth wrong value also invalidates the link.
      def verify_code(raw_token:, code:, organization:)
        token = token_model.peek(raw: raw_token, organization:, purpose: PURPOSE)
        return unless token

        attempts = attempt_store.record_attempt!(
          organization_id: token.decidim_organization_id,
          user_id: token.decidim_user_id,
          purpose: token.purpose,
          ttl: (token.expires_at - clock.call).ceil
        )
        return invalidate(raw_token, organization) if attempts > MAX_ATTEMPTS

        supplied = code.to_s.strip
        valid = supplied.match?(/\A\d{#{CODE_LENGTH}}\z/) &&
                ActiveSupport::SecurityUtils.secure_compare(code_for(raw_token), supplied)
        return token if valid

        invalidate(raw_token, organization) if attempts >= MAX_ATTEMPTS
        nil
      end

      # Atomically claims the shared LoginToken after proof and grant checks.
      # The attempt key deliberately survives a successful claim until its
      # fixed challenge window expires. Clearing it could race a concurrent
      # resend and erase the newer challenge's budget.
      def consume!(raw_token:, organization:)
        token_model.consume!(raw: raw_token, organization:, purpose: PURPOSE)
      end

      private

      attr_reader :token_model, :attempt_store, :clock

      def invalidate(raw_token, organization)
        token_model.consume!(raw: raw_token, organization:, purpose: PURPOSE)
        nil
      end

      def code_for(raw_token)
        digest = OpenSSL::HMAC.digest("SHA256", code_key, raw_token.to_s)
        format("%0#{CODE_LENGTH}d", digest.unpack1("Q>") % (10**CODE_LENGTH))
      end

      def code_key
        return @code_key if @code_key

        secret = Rails.application.secret_key_base.to_s
        raise ArgumentError, "secret_key_base is required for phone login challenges" if secret.empty?

        @code_key = ActiveSupport::KeyGenerator.new(secret).generate_key(CODE_KEY_SALT, 32)
      end
    end
  end
end

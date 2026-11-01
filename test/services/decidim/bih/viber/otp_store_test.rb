# frozen_string_literal: true

require "test_helper"
require "json"
require "active_support/message_encryptor"
require_relative "../../../../../app/services/decidim/bih/viber/otp_store"

module Decidim
  module Bih
    module Viber
      # Unit coverage for the security-critical guard logic in OtpStore: the
      # Redis-backed scratch storage for the Viber OTP verification flow.
      #
      # The store is exercised in full isolation (no Rails host, no live DB, no
      # real Redis) by injecting a faithful in-memory fake that models the exact
      # subset of the Redis command contract the store relies on: GET/SET (with
      # the +ex:+ expiry option), DEL, INCR, and EXPIRE. The fake also tracks the
      # TTLs that were set so we can assert the store applies the right windows
      # WITHOUT sleeping.
      #
      # Guards asserted here:
      #   * digest-only storage — the plaintext OTP never reaches the store; only
      #     the HMAC digest handed to #put is persisted (and round-trips intact).
      #   * fresh #put resets the attempt counter (a new code can never inherit a
      #     near-locked counter).
      #   * #increment_attempts is backed by the atomic Redis INCR (monotonic) and
      #     no-ops when there is no pending OTP.
      #   * per-SENDER and per-DESTINATION-PHONE send caps each allow exactly
      #     SEND_MAX / SEND_TO_MAX sends per window, are independent, and are
      #     scoped by organization so two tenants never share a counter.
      class OtpStoreTest < Minitest::Test
        # Minimal, faithful in-memory Redis fake. Only the commands OtpStore uses
        # are implemented; each behaves like the real server for the store's needs.
        class FakeRedis
          attr_reader :store, :ttls

          def initialize
            @store = {}
            @ttls = {}
          end

          def get(key)
            @store[key]
          end

          # +ex:+ mirrors the real Redis SET expiry keyword, so the name is fixed
          # by the contract OtpStore calls against.
          def set(key, value, ex: nil) # rubocop:disable Naming/MethodParameterName
            @store[key] = value.to_s
            @ttls[key] = ex unless ex.nil?
            "OK"
          end

          # Real Redis DEL accepts one or more keys and returns the count removed.
          def del(*keys)
            removed = 0
            keys.flatten.each do |key|
              removed += 1 if @store.delete(key)
              @ttls.delete(key)
            end
            removed
          end

          # INCR creates the key at 1 when absent, otherwise atomically bumps it.
          def incr(key)
            @store[key] = ((@store[key] || 0).to_i + 1)
            @store[key]
          end

          def expire(key, seconds)
            return false unless @store.has_key?(key)

            @ttls[key] = seconds
            true
          end

          # OtpStore uses one tiny Lua script so rollback compensation cannot
          # race another webhook's INCR. Model the script's observable result.
          def eval(script, keys:, argv: [])
            if script == OtpStore::PUT_SCRIPT
              set(keys.fetch(0), argv.fetch(0), ex: argv.fetch(1).to_i)
              del(keys.fetch(1))
              return "OK"
            end

            if script == OtpStore::INCREMENT_COUNTER_SCRIPT
              value = incr(keys.fetch(0))
              expire(keys.fetch(0), argv.fetch(0).to_i) if value == 1
              return value
            end

            key = keys.fetch(0)
            return 0 unless @store.has_key?(key)

            value = @store[key].to_i - 1
            if value <= 0
              del(key)
              0
            else
              @store[key] = value
            end
          end
        end

        class FakeTransaction
          def initialize
            @commit_callbacks = []
            @rollback_callbacks = []
          end

          def open? = true

          def after_commit(&block) = @commit_callbacks << block

          def after_rollback(&block) = @rollback_callbacks << block

          def commit = @commit_callbacks.each(&:call)

          def rollback = @rollback_callbacks.reverse_each(&:call)
        end

        SENDER = "viber-sender-abc"
        PHONE = "38765123456"
        DIGEST = "a" * 64 # stand-in for an HMAC-SHA256 hex digest

        def setup
          @redis = FakeRedis.new
          @hmac_key = "h" * 32
          @encryptor = ActiveSupport::MessageEncryptor.new("e" * 32)
          @store = build_store(organization_id: 42)
        end

        # --- digest-only storage -------------------------------------------------

        def test_put_persists_only_the_digest_and_never_the_plaintext_code
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)

          # The single OTP value written to Redis must carry the digest + phone,
          # and must NOT contain anything resembling the 6-digit plaintext.
          stored_raw = @redis.store.fetch(otp_key)
          parsed = JSON.parse(@encryptor.decrypt_and_verify(stored_raw, purpose: OtpStore::ENCRYPTION_PURPOSE))

          assert_equal DIGEST, parsed["digest"]
          assert_equal PHONE, parsed["phone"]
          assert_nil stored_raw[/\b\d{6}\b/], "raw plaintext OTP must never be stored"
        end

        def test_get_round_trips_the_pending_otp_as_a_symbol_keyed_hash
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)

          pending = @store.get(sender: SENDER)

          assert_equal PHONE, pending[:phone]
          assert_equal DIGEST, pending[:digest]
          assert_kind_of Integer, pending[:created_at]
        end

        def test_get_returns_nil_when_no_pending_otp
          assert_nil @store.get(sender: SENDER)
        end

        def test_put_applies_the_pending_otp_ttl
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)

          assert_equal OtpStore::DEFAULT_TTL, @redis.ttls.fetch(otp_key)
        end

        def test_put_honours_an_explicit_ttl_override
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST, ttl: 60)

          assert_equal 60, @redis.ttls.fetch(otp_key)
        end

        def test_put_clamps_an_excessive_ttl_to_the_security_maximum
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST, ttl: OtpStore::DEFAULT_TTL * 100)

          assert_equal OtpStore::DEFAULT_TTL, @redis.ttls.fetch(otp_key)
        end

        def test_pending_otp_is_captured_as_a_durable_effect_during_inbound_processing
          capture = Decidim::Bih::DurableEffects.capture do
            @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          end

          assert_nil @redis.get(otp_key)
          assert_equal(["redis_eval"], capture.effects.map { |effect| effect.fetch("type") })
          assert_equal "viber_otp_put_v1", capture.effects.first.fetch("script_id")

          Decidim::Bih::DurableEffects.dispatch!(capture.effects.first, redis: @redis)
          assert_equal PHONE, @store.get(sender: SENDER)[:phone]
        end

        def test_expired_captured_otp_is_not_recreated_during_late_recovery
          capture = Decidim::Bih::DurableEffects.capture do
            @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          end
          capture.effects.first["deadline_at_ms"] = 1

          assert_equal :expired, Decidim::Bih::DurableEffects.dispatch!(capture.effects.first, redis: @redis)
          assert_nil @store.get(sender: SENDER)
        end

        # --- attempt counter: reset on fresh send -------------------------------

        def test_fresh_put_resets_the_attempt_counter
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          @store.increment_attempts(sender: SENDER)
          @store.increment_attempts(sender: SENDER)

          assert_equal 2, @redis.store.fetch(attempts_key)

          # A re-send must wipe the near-locked counter so a new code starts clean.
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)

          assert_equal false, @redis.store.has_key?(attempts_key), "fresh OTP must clear the attempt counter"
          assert_equal 1, @store.increment_attempts(sender: SENDER)
        end

        # --- attempt counter: atomic monotonic increment + lockout window -------

        def test_increment_attempts_is_monotonic_and_returns_the_new_count
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)

          assert_equal 1, @store.increment_attempts(sender: SENDER)
          assert_equal 2, @store.increment_attempts(sender: SENDER)
          assert_equal 3, @store.increment_attempts(sender: SENDER)
        end

        def test_increment_attempts_is_a_noop_without_a_pending_otp
          # No #put first: there is nothing to guess against, so the counter must
          # not be created (otherwise an attacker could pre-inflate it / probe).
          assert_nil @store.increment_attempts(sender: SENDER)
          assert_equal false, @redis.store.has_key?(attempts_key)
        end

        def test_increment_attempts_sets_the_counter_ttl_only_on_first_bump
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          @redis.ttls.delete(attempts_key)

          @store.increment_attempts(sender: SENDER)
          assert_equal OtpStore::DEFAULT_TTL, @redis.ttls.fetch(attempts_key)

          # A subsequent bump must NOT re-arm the TTL (the window is anchored to
          # the first wrong guess, not the latest one).
          @redis.ttls.delete(attempts_key)
          @store.increment_attempts(sender: SENDER)
          assert_equal false, @redis.ttls.has_key?(attempts_key)
        end

        def test_database_rollback_compensates_a_wrong_code_attempt
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          transaction = FakeTransaction.new

          @store.stub(:active_transaction, transaction) do
            assert_equal 1, @store.increment_attempts(sender: SENDER)
            transaction.rollback
          end

          assert_equal false, @redis.store.has_key?(attempts_key)
        end

        def test_clear_drops_both_the_pending_otp_and_the_attempt_counter
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          @store.increment_attempts(sender: SENDER)

          @store.clear(sender: SENDER)

          assert_nil @store.get(sender: SENDER)
          assert_equal false, @redis.store.has_key?(attempts_key)
        end

        def test_pending_clear_is_captured_as_a_durable_effect
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          capture = Decidim::Bih::DurableEffects.capture do
            @store.clear(sender: SENDER)
          end

          assert_equal PHONE, @store.get(sender: SENDER)[:phone]
          assert_equal(["redis_delete"], capture.effects.map { |effect| effect.fetch("type") })

          Decidim::Bih::DurableEffects.dispatch!(capture.effects.first, redis: @redis)
          assert_nil @store.get(sender: SENDER)
        end

        # --- per-sender send cap -------------------------------------------------

        def test_allow_send_permits_exactly_send_max_per_window
          results = Array.new(OtpStore::SEND_MAX + 2) { @store.allow_send?(sender: SENDER) }

          assert_equal Array.new(OtpStore::SEND_MAX, true) + [false, false], results
        end

        def test_allow_send_arms_the_window_ttl_on_the_first_send
          @store.allow_send?(sender: SENDER)

          assert_equal OtpStore::SEND_WINDOW, @redis.ttls.fetch(send_key)
        end

        def test_database_rollback_restores_the_sender_send_budget
          transaction = FakeTransaction.new

          @store.stub(:active_transaction, transaction) do
            assert @store.allow_send?(sender: SENDER)
            transaction.rollback
          end

          OtpStore::SEND_MAX.times do
            assert @store.allow_send?(sender: SENDER)
          end
          assert_equal false, @store.allow_send?(sender: SENDER)
        end

        def test_allow_send_counters_are_independent_per_sender
          OtpStore::SEND_MAX.times { @store.allow_send?(sender: SENDER) }

          # A different sender starts with a clean budget.
          assert @store.allow_send?(sender: "other-sender")
        end

        # --- per-destination-phone send cap (anti SMS-bomb) ---------------------

        def test_allow_send_to_permits_exactly_send_to_max_per_window
          results = Array.new(OtpStore::SEND_TO_MAX + 2) { @store.allow_send_to?(phone: PHONE) }

          assert_equal Array.new(OtpStore::SEND_TO_MAX, true) + [false, false], results
        end

        def test_sender_and_destination_caps_are_tracked_independently
          # Exhausting the sender cap must NOT consume the destination budget, and
          # vice versa — they protect against different abuse vectors.
          OtpStore::SEND_MAX.times { @store.allow_send?(sender: SENDER) }
          assert_equal false, @store.allow_send?(sender: SENDER)

          assert @store.allow_send_to?(phone: PHONE), "destination cap must be untouched by the sender cap"
        end

        # --- organization scoping ------------------------------------------------

        def test_pending_otp_is_scoped_by_organization
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)

          other_org = build_store(organization_id: 99)
          assert_nil other_org.get(sender: SENDER), "same sender under another org must not collide"
        end

        def test_send_caps_are_scoped_by_organization
          OtpStore::SEND_MAX.times { @store.allow_send?(sender: SENDER) }
          assert_equal false, @store.allow_send?(sender: SENDER)

          other_org = build_store(organization_id: 99)
          assert other_org.allow_send?(sender: SENDER), "another org's send budget must be independent"
        end

        def test_for_organization_returns_a_store_bound_to_that_org_sharing_the_redis
          base = build_store(organization_id: nil)
          bound = base.for_organization(7)

          bound.put(sender: SENDER, phone: PHONE, digest: DIGEST)

          # The bound copy shares the same (fake) Redis connection but a distinct,
          # org-scoped key, so a differently-scoped store cannot read it.
          assert_equal PHONE, bound.get(sender: SENDER)[:phone]
          assert_nil build_store(organization_id: 7777).get(sender: SENDER)
        end

        def test_redis_keys_never_expose_sender_or_phone
          @store.put(sender: SENDER, phone: PHONE, digest: DIGEST)
          @store.allow_send?(sender: SENDER)
          @store.allow_send_to?(phone: PHONE)

          serialized_keys = @redis.store.keys.join(" ")
          refute_includes serialized_keys, SENDER
          refute_includes serialized_keys, PHONE
        end

        private

        def otp_key
          @store.send(:otp_key, SENDER)
        end

        def attempts_key
          @store.send(:attempts_key, SENDER)
        end

        def send_key
          @store.send(:send_key, SENDER)
        end

        def build_store(organization_id:)
          OtpStore.new(redis: @redis, organization_id:, hmac_key: @hmac_key, encryptor: @encryptor)
        end
      end
    end
  end
end

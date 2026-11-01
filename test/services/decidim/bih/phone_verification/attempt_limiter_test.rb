# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require_relative "../../../../../app/services/decidim/bih/phone_verification/attempt_limiter"

class AttemptLimiterTest < Minitest::Test
  class FakeRedis
    def initialize
      @store = {}
      @ttl = {}
    end

    def incr(key) = @store[key] = @store.fetch(key, 0) + 1

    def expire(key, seconds) = @ttl[key] = seconds

    def get(key) = @store[key]&.to_s

    def del(key) = @store.delete(key)

    def ttl_for(key) = @ttl[key]

    # Note: this `eval` is the Redis client's EVAL command (runs a Lua script
    # server-side), not Ruby's Kernel#eval — no Ruby string is evaluated here.
    # Mirrors the atomic INCR-then-conditionally-EXPIRE Lua script: increment
    # the sole key, and set the TTL only on the very first increment.
    def eval(_script, keys:, argv:)
      key = keys.first
      value = incr(key)
      expire(key, argv.first) if value == 1
      value
    end
  end

  class BrokenRedis
    def incr(*) = raise(IOError, "down")

    def get(*) = raise(IOError, "down")

    def expire(*) = raise(IOError, "down")

    def del(*) = raise(IOError, "down")

    def eval(*) = raise(IOError, "down")
  end

  def limiter(redis = FakeRedis.new, version: 1)
    Decidim::Bih::PhoneVerification::AttemptLimiter.new(organization_id: 1, authorization_id: 42, challenge_version: version, redis:)
  end

  def test_fifth_failure_exhausts_the_challenge
    l = limiter
    4.times { l.record_failure! }
    refute l.exhausted?
    l.record_failure!
    assert l.exhausted?
  end

  def test_a_new_challenge_version_starts_fresh
    redis = FakeRedis.new
    5.times { limiter(redis, version: 1).record_failure! }
    refute limiter(redis, version: 2).exhausted?
  end

  def test_first_failure_sets_the_code_lifetime_ttl
    redis = FakeRedis.new
    l = limiter(redis)
    l.record_failure!
    key = redis.instance_variable_get(:@store).keys.first
    assert_equal 24.hours.to_i, redis.ttl_for(key)
  end

  def test_redis_outage_fails_closed
    assert limiter(BrokenRedis.new).exhausted?
  end

  # Fail-closed and "you have used your five attempts" are the same answer to
  # the code path and two very different things to say to a citizen, so the
  # caller has to be able to tell them apart.
  def test_a_store_outage_is_distinguishable_from_a_real_lockout
    broken = limiter(BrokenRedis.new)

    assert broken.exhausted?
    assert broken.store_error?

    healthy = limiter
    5.times { healthy.record_failure! }

    assert healthy.exhausted?
    refute healthy.store_error?, "a genuine lockout is not an outage"
  end

  def test_a_failed_write_is_also_reported_as_a_store_error
    broken = limiter(BrokenRedis.new)

    assert_equal Decidim::Bih::PhoneVerification::AttemptLimiter::MAX_ATTEMPTS, broken.record_failure!
    assert broken.store_error?
  end

  def test_key_does_not_contain_raw_identifiers
    redis = FakeRedis.new
    l = Decidim::Bih::PhoneVerification::AttemptLimiter.new(
      organization_id: 777, authorization_id: 424_242, challenge_version: 1_700_000_000, redis:
    )
    l.record_failure!
    key = redis.instance_variable_get(:@store).keys.first
    refute_includes key, "777"
    refute_includes key, "424242"
    refute_includes key, "1700000000"
  end
end

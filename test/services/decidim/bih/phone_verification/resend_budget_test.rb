# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require_relative "../../../../../app/services/decidim/bih/phone_verification/attempt_limiter"
require_relative "../../../../../app/services/decidim/bih/phone_verification/resend_budget"

# Every accepted resend spends real money (a Viber/WhatsApp/SMS message to a
# number the citizen typed, not necessarily their own). The 60-second cooldown
# alone caps the rate, not the total: rotating sessions turns it into ~15
# messages per 15 minutes aimed at a third party's phone. This is the total.
class ResendBudgetTest < Minitest::Test
  # Same doubles as the AttemptLimiter unit test, kept local so this file
  # does not depend on that one having been loaded first. `eval` is the Redis
  # client's EVAL command, not Ruby's Kernel#eval.
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

    def eval(_script, keys:, argv:)
      key = keys.first
      value = incr(key)
      expire(key, argv.first) if value == 1
      value
    end
  end

  class BrokenRedis
    def get(*) = raise(IOError, "down")

    def del(*) = raise(IOError, "down")

    def eval(*, **) = raise(IOError, "down")
  end

  def budget(redis = FakeRedis.new, version: 1)
    Decidim::Bih::PhoneVerification::ResendBudget.new(
      organization_id: 1, authorization_id: 42, challenge_version: version, redis:
    )
  end

  def test_five_resends_are_free_and_the_sixth_is_not
    redis = FakeRedis.new
    5.times do
      refute budget(redis).exhausted?
      budget(redis).spend!
    end

    assert budget(redis).exhausted?
  end

  def test_the_budget_lives_fifteen_minutes
    redis = FakeRedis.new
    budget(redis).spend!
    key = redis.instance_variable_get(:@store).keys.first

    assert_equal 900, redis.ttl_for(key)
    assert_equal 900, Decidim::Bih::PhoneVerification::ResendBudget::TTL_SECONDS
    assert_equal 5, Decidim::Bih::PhoneVerification::ResendBudget::MAX_RESENDS
  end

  # The caller decides on the value the INCR came back with, never on a
  # separate read: two requests that both read "four spent" and then both send
  # are exactly the amplification this counter exists to stop.
  def test_spend_returns_the_running_count
    redis = FakeRedis.new

    spends = (1..5).map { budget(redis).spend! }

    assert_equal [1, 2, 3, 4, 5], spends
    assert_equal 6, budget(redis).spend!, "the count keeps climbing past the limit"
  end

  # A changed number destroys the authorization row, so the next one carries a
  # new id and a new created_at — a legitimately fresh budget.
  def test_a_new_challenge_starts_a_fresh_budget
    redis = FakeRedis.new
    5.times { budget(redis, version: 1).spend! }

    refute budget(redis, version: 2).exhausted?
  end

  # Wrong codes and paid messages are two different budgets: burning the code
  # attempts must not also stop the citizen from asking for another message,
  # and neither may a resend buy a fresh set of guesses.
  def test_the_resend_budget_does_not_share_a_key_with_the_attempt_limiter
    redis = FakeRedis.new
    attempts = Decidim::Bih::PhoneVerification::AttemptLimiter.new(
      organization_id: 1, authorization_id: 42, challenge_version: 1, redis:
    )
    5.times { attempts.record_failure! }

    refute budget(redis).exhausted?
    budget(redis).spend!

    assert_equal 2, redis.instance_variable_get(:@store).keys.uniq.size
    assert attempts.exhausted?, "spending a resend must not reset the wrong-code counter"
  end

  # Money direction: an unreadable counter refuses the send.
  def test_a_store_outage_refuses_the_send
    broken = budget(BrokenRedis.new)

    assert broken.exhausted?
    assert broken.store_error?
  end

  def test_a_failed_spend_is_reported_as_a_store_error
    broken = budget(BrokenRedis.new)

    assert_equal Decidim::Bih::PhoneVerification::ResendBudget::MAX_RESENDS, broken.spend!
    assert broken.store_error?
  end

  def test_key_does_not_contain_raw_identifiers
    redis = FakeRedis.new
    Decidim::Bih::PhoneVerification::ResendBudget.new(
      organization_id: 777, authorization_id: 424_242, challenge_version: 1_700_000_000, redis:
    ).spend!
    key = redis.instance_variable_get(:@store).keys.first

    refute_includes key, "777"
    refute_includes key, "424242"
    refute_includes key, "1700000000"
  end
end

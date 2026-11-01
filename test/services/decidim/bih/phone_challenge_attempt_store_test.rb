# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/numeric/time"

module Decidim
  module Bih
    unless const_defined?(:LoginToken)
      class LoginToken
        LOGIN_TTL = 10.minutes
      end
    end
  end
end

require_relative "../../../../app/services/decidim/bih/phone_challenge"

module Decidim
  module Bih
    class PhoneChallengeAttemptStoreTest < Minitest::Test
      class FakeRedis
        attr_accessor :ping_response
        attr_reader :evaluations

        def initialize
          @ping_response = "PONG"
          @evaluations = []
          @counts = Hash.new(0)
        end

        def ping = ping_response

        def eval(script, keys:, argv:)
          @evaluations << { script:, keys:, argv: }
          return @counts[keys.fetch(0)] += 1 if script == PhoneChallenge::AttemptStore::INCREMENT_SCRIPT

          @counts.has_key?(keys.fetch(0)) ? 600 : -2
        end
      end

      def setup
        @redis = FakeRedis.new
        @store = PhoneChallenge::AttemptStore.new(redis: @redis, hmac_key: "h" * 32)
      end

      def test_availability_check_fails_closed_on_unexpected_ping_response
        @redis.ping_response = ""

        assert_raises(Redis::BaseError) { @store.available! }
      end

      def test_increment_is_atomic_bounded_and_uses_ten_minute_ttl
        values = 3.times.map do
          @store.record_attempt!(organization_id: 42, user_id: 7, purpose: "login", ttl: 3.hours)
        end

        assert_equal [1, 2, 3], values
        assert_equal PhoneChallenge::AttemptStore::INCREMENT_SCRIPT, @redis.evaluations.first.fetch(:script)
        assert_includes PhoneChallenge::AttemptStore::INCREMENT_SCRIPT, "current < required"
        assert_equal 5, PhoneChallenge::MAX_ATTEMPTS
        assert_equal [10.minutes.to_i], @redis.evaluations.first.fetch(:argv)
      end

      def test_keys_are_stable_scoped_hmacs_without_raw_identifiers
        @store.record_attempt!(organization_id: 42, user_id: 7, purpose: "login", ttl: 600)
        @store.record_attempt!(organization_id: 42, user_id: 7, purpose: "login", ttl: 600)
        @store.record_attempt!(organization_id: 43, user_id: 7, purpose: "login", ttl: 600)
        keys = @redis.evaluations.map { |call| call.fetch(:keys).first }

        assert_equal keys[0], keys[1]
        refute_equal keys[0], keys[2]
        refute_includes keys.join(" "), ":42:"
        refute_includes keys.join(" "), ":43:"
        refute_includes keys.join(" "), ":7:"
        assert(keys.all? { |key| key.match?(/\Abih:phone-login:attempts:[0-9a-f]{64}\z/) })
      end

      def test_extend_expiry_uses_a_separate_script_without_changing_the_count
        args = { organization_id: 42, user_id: 7, purpose: "login" }
        @store.record_attempt!(**args, ttl: 60)

        assert_equal 600, @store.extend_expiry!(**args, ttl: 10.minutes)
        assert_equal PhoneChallenge::AttemptStore::EXTEND_SCRIPT, @redis.evaluations.last.fetch(:script)
        assert_equal [10.minutes.to_i], @redis.evaluations.last.fetch(:argv)
        assert_equal 2, @store.record_attempt!(**args, ttl: 60)
      end
    end
  end
end

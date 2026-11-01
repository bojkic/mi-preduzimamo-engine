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
    class PhoneChallengeTest < Minitest::Test
      Organization = Struct.new(:id)
      User = Struct.new(:id, :organization)
      Token = Struct.new(
        :decidim_user_id,
        :decidim_organization_id,
        :purpose,
        :phone,
        :user,
        :expires_at,
        keyword_init: true
      )

      class FakeTokenModel
        LOGIN_TTL = 10.minutes

        attr_reader :issued

        def initialize(clock: -> { Time.current })
          @issued = []
          @records = {}
          @sequence = 0
          @clock = clock
        end

        def ttl_for(purpose)
          raise "unexpected purpose" unless purpose == "login"

          LOGIN_TTL
        end

        def issue!(user:, purpose:, phone:)
          @records.clear
          @sequence += 1
          raw = "raw-secret-#{@sequence}"
          @records[raw] = Token.new(
            decidim_user_id: user.id,
            decidim_organization_id: user.organization.id,
            purpose:,
            phone:,
            user:,
            expires_at: @clock.call + LOGIN_TTL
          )
          @issued << { user:, purpose:, phone:, raw: }
          raw
        end

        def peek(raw:, organization:, purpose: nil)
          token = @records[raw]
          return unless token
          return unless token.decidim_organization_id == organization.id
          return if purpose && token.purpose != purpose

          token
        end

        def consume!(raw:, organization:, purpose: nil)
          token = peek(raw:, organization:, purpose:)
          @records.delete(raw) if token
          token
        end
      end

      class FakeAttemptStore
        attr_reader :attempts
        attr_accessor :available

        def initialize(clock: -> { Time.current })
          @attempts = Hash.new(0)
          @available = true
          @expires_at = {}
          @clock = clock
        end

        def available!
          raise Redis::CannotConnectError, "offline" unless available

          true
        end

        def record_attempt!(organization_id:, user_id:, purpose:, **)
          key = [organization_id, user_id, purpose]
          expire_if_due(key)
          @attempts[key] += 1
        end

        def extend_expiry!(organization_id:, user_id:, purpose:, ttl:)
          key = [organization_id, user_id, purpose]
          expire_if_due(key)
          return unless @attempts.has_key?(key)

          requested = @clock.call + ttl
          @expires_at[key] = [@expires_at[key], requested].compact.max
        end

        private

        def expire_if_due(key)
          return unless @expires_at[key] && @expires_at[key] <= @clock.call

          @attempts.delete(key)
          @expires_at.delete(key)
        end
      end

      def setup
        @organization = Organization.new(42)
        @other_organization = Organization.new(43)
        @user = User.new(7, @organization)
        @now = Time.utc(2026, 9, 5, 12, 0, 0)
        clock = -> { @now }
        @tokens = FakeTokenModel.new(clock:)
        @attempts = FakeAttemptStore.new(clock:)
        @challenge = PhoneChallenge.new(
          token_model: @tokens,
          attempt_store: @attempts,
          code_key: "k" * 32,
          clock: -> { @now }
        )
      end

      def test_issue_creates_a_fresh_phone_bound_login_token_and_six_digit_code
        result = issue

        assert_match(/\A\d{6}\z/, result.otp_code)
        assert_equal @now + 10.minutes, result.expires_at
        assert_equal({ user: @user, purpose: "login", phone: "+38765123456", raw: result.raw_token }, @tokens.issued.last)
      end

      def test_issue_fails_closed_before_creating_a_token_when_redis_is_unavailable
        @attempts.available = false

        assert_raises(Redis::CannotConnectError) { issue }
        assert_empty @tokens.issued
      end

      def test_code_is_derived_from_raw_secret_and_application_key
        first = issue
        other_key = PhoneChallenge.new(
          token_model: @tokens,
          attempt_store: @attempts,
          code_key: "z" * 32,
          clock: -> { @now }
        )
        second = other_key.issue!(user: @user, phone: "+38765123456")

        refute_equal first.otp_code, second.otp_code
        refute_includes first.otp_code, LoginToken.digest(first.raw_token) if LoginToken.respond_to?(:digest)
      end

      def test_correct_code_is_only_proof_until_the_shared_token_is_consumed
        result = issue

        proof = @challenge.verify_code(raw_token: result.raw_token, code: result.otp_code, organization: @organization)

        assert_equal @user, proof.user
        assert_equal proof, @tokens.peek(raw: result.raw_token, organization: @organization, purpose: "login")
        assert_equal proof, @challenge.consume!(raw_token: result.raw_token, organization: @organization)
        assert_nil @challenge.consume!(raw_token: result.raw_token, organization: @organization)
      end

      def test_code_and_link_share_one_atomic_token_claim
        result = issue
        proof = @challenge.verify_code(raw_token: result.raw_token, code: result.otp_code, organization: @organization)
        link_claim = @tokens.consume!(raw: result.raw_token, organization: @organization, purpose: "login")

        assert proof
        assert link_claim
        assert_nil @challenge.consume!(raw_token: result.raw_token, organization: @organization)
      end

      def test_every_wrong_or_malformed_submission_counts_and_fifth_invalidates_link
        result = issue
        wrong_values = ["", "12345", "abcdef", "000000", "999999"]
        wrong_values.map! { |value| value == result.otp_code ? "111111" : value }

        wrong_values.each do |value|
          assert_nil @challenge.verify_code(raw_token: result.raw_token, code: value, organization: @organization)
        end

        key = [@organization.id, @user.id, "login"]
        assert_equal PhoneChallenge::MAX_ATTEMPTS, @attempts.attempts[key]
        assert_nil @tokens.peek(raw: result.raw_token, organization: @organization, purpose: "login")
      end

      def test_resend_invalidates_old_link_without_resetting_attempt_budget
        first = issue
        4.times do
          @challenge.verify_code(raw_token: first.raw_token, code: wrong_code(first.otp_code), organization: @organization)
        end
        second = issue

        assert_nil @tokens.peek(raw: first.raw_token, organization: @organization, purpose: "login")
        assert_nil @challenge.verify_code(
          raw_token: second.raw_token,
          code: wrong_code(second.otp_code),
          organization: @organization
        )
        assert_nil @tokens.peek(raw: second.raw_token, organization: @organization, purpose: "login")
      end

      def test_resend_extends_existing_budget_to_new_absolute_expiry_without_resetting_it
        first = issue
        @challenge.verify_code(
          raw_token: first.raw_token,
          code: wrong_code(first.otp_code),
          organization: @organization
        )
        @now += 9.minutes
        second = issue
        3.times do
          @challenge.verify_code(
            raw_token: second.raw_token,
            code: wrong_code(second.otp_code),
            organization: @organization
          )
        end

        @now += 61.seconds # Past the first challenge's original t+10m boundary.
        assert_nil @challenge.verify_code(
          raw_token: second.raw_token,
          code: wrong_code(second.otp_code),
          organization: @organization
        )
        assert_nil @tokens.peek(raw: second.raw_token, organization: @organization, purpose: "login")
      end

      def test_challenge_is_bound_to_organization
        result = issue

        assert_nil @challenge.verify_code(raw_token: result.raw_token, code: result.otp_code, organization: @other_organization)
        assert_empty @attempts.attempts
      end

      def test_successful_consume_keeps_attempt_budget_for_a_concurrent_later_login
        result = issue
        proof = @challenge.verify_code(raw_token: result.raw_token, code: result.otp_code, organization: @organization)

        assert proof
        @challenge.consume!(raw_token: result.raw_token, organization: @organization)
        later = issue
        4.times do
          @challenge.verify_code(
            raw_token: later.raw_token,
            code: wrong_code(later.otp_code),
            organization: @organization
          )
        end

        assert_nil @tokens.peek(raw: later.raw_token, organization: @organization, purpose: "login")
        assert_equal PhoneChallenge::MAX_ATTEMPTS, @attempts.attempts[[@organization.id, @user.id, "login"]]
      end

      private

      def issue
        @challenge.issue!(user: @user, phone: "+387 65 123-456")
      end

      def wrong_code(correct)
        correct == "000000" ? "000001" : "000000"
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"
require "digest"

# The LoginToken model normally inherits from Decidim::ApplicationRecord (an
# ActiveRecord base that needs a DB connection). To exercise its host-free guard
# LOGIC in isolation we provide a minimal stand-in base class that records the
# class-macro calls the model makes at load time, without any database. This is
# defined only if the real constant is absent, and is torn down afterwards so it
# can never leak a too-thin base class into other test files.
module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      def self.table_name=(*); end

      def self.belongs_to(*); end

      def self.validates(*); end

      def self.where(*) = raise("unexpected database query")
    end
    LOGIN_TOKEN_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../app/models/decidim/bih/login_token"

module Decidim
  if const_defined?(:LOGIN_TOKEN_TEST_DEFINED_APPLICATION_RECORD, false)
    remove_const(:ApplicationRecord)
    remove_const(:LOGIN_TOKEN_TEST_DEFINED_APPLICATION_RECORD)
  end

  module Bih
    # Unit coverage for the host-free guard logic on the single-use magic-link
    # token model. The single-use consume semantics, the "GET-peek must not
    # consume", and the expiry-window scoping all run through ActiveRecord
    # query/transaction calls against a live table — those are covered by the
    # integration suite, NOT here (see this task's integration-gap notes).
    #
    # What IS unit-isolable and asserted here:
    #   * SHA-256 digest storage — the raw token is hashed, never kept verbatim,
    #     and the digest is deterministic & collision-distinct.
    #   * the PURPOSES allowlist (retired "viber_verify" can no longer be minted).
    #   * the TTL constants (short SMS/login lifetime vs. long postal lifetime).
    #   * #peek's blank-token short-circuit, which returns nil WITHOUT touching
    #     the database (a guard that an empty/nil token never matches a row).
    class LoginTokenTest < Minitest::Test
      RAW = "x7Yt-rawtoken-value_24chars"

      class ClaimScope
        attr_reader :conditions, :updated_at

        def initialize(update_count: 1)
          @update_count = update_count
          @conditions = []
        end

        def where(conditions)
          @conditions << conditions
          self
        end

        def update_all(consumed_at:)
          @updated_at = consumed_at
          @update_count
        end
      end

      def test_digest_is_the_sha256_hex_of_the_raw_token
        assert_equal Digest::SHA256.hexdigest(RAW), LoginToken.digest(RAW)
      end

      def test_digest_is_deterministic
        assert_equal LoginToken.digest(RAW), LoginToken.digest(RAW)
      end

      def test_digest_never_echoes_the_raw_token
        digest = LoginToken.digest(RAW)

        assert_nil digest[RAW], "the raw token must never appear inside its digest"
        assert_equal 64, digest.length, "SHA-256 hex digest is 64 chars"
        assert_match(/\A[0-9a-f]{64}\z/, digest)
      end

      def test_distinct_raw_tokens_produce_distinct_digests
        assert_operator LoginToken.digest("token-a"), :!=, LoginToken.digest("token-b")
      end

      def test_purposes_allowlist_excludes_the_retired_viber_verify_purpose
        assert_equal %w(verify login postal invitation), LoginToken::PURPOSES
        assert_equal false, LoginToken::PURPOSES.include?("viber_verify"),
                     "the retired, page-displayed token purpose must not be mintable"
      end

      def test_sms_and_login_tokens_are_short_lived
        assert_equal 10 * 60, LoginToken::TTL.to_i
      end

      def test_postal_tokens_live_far_longer_so_the_letter_can_be_delivered
        assert_equal 30 * 24 * 60 * 60, LoginToken::POSTAL_TTL.to_i
        assert_operator LoginToken::POSTAL_TTL, :>, LoginToken::TTL
      end

      def test_peek_short_circuits_to_nil_for_a_blank_token_without_touching_the_db
        # organization is nil and no AR connection exists; reaching a query would
        # raise. Returning nil proves the blank guard runs first.
        assert_nil LoginToken.peek(raw: "", organization: nil)
        assert_nil LoginToken.peek(raw: nil, organization: nil)
      end

      def test_claim_atomically_requires_unconsumed_and_unexpired_record
        token = Struct.new(:id).new(17)
        scope = ClaimScope.new

        LoginToken.stub(:where, ->(**conditions) { scope.where(conditions) }) do
          assert_equal token, LoginToken.claim!(token)
        end

        assert_includes scope.conditions, { id: 17, consumed_at: nil }
        expiry_scope = scope.conditions.find { |condition| condition.has_key?(:expires_at) }
        assert_kind_of Range, expiry_scope.fetch(:expires_at)
        assert expiry_scope.fetch(:expires_at).begin <= scope.updated_at
      end

      def test_claim_returns_nil_when_atomic_update_loses_the_race
        token = Struct.new(:id).new(17)
        scope = ClaimScope.new(update_count: 0)

        LoginToken.stub(:where, ->(**conditions) { scope.where(conditions) }) do
          assert_nil LoginToken.claim!(token)
        end
      end

      def test_verify_tokens_expire_after_twenty_four_hours
        assert_equal 24.hours, Decidim::Bih::LoginToken::VERIFY_TTL
        assert_equal 24.hours, Decidim::Bih::LoginToken.ttl_for("verify")
      end

      def test_the_wrong_code_budget_lives_exactly_as_long_as_the_verify_code
        require_relative "../../../../app/services/decidim/bih/phone_verification/attempt_limiter"
        assert_equal Decidim::Bih::LoginToken::VERIFY_TTL.to_i,
                     Decidim::Bih::PhoneVerification::AttemptLimiter::TTL_SECONDS
      end

      def test_login_links_expire_after_ten_minutes
        assert_equal 10.minutes, Decidim::Bih::LoginToken::LOGIN_TTL
        assert_equal 10.minutes, Decidim::Bih::LoginToken.ttl_for("login")
      end

      def test_postal_ttl_is_unchanged
        assert_equal 30.days, Decidim::Bih::LoginToken.ttl_for("postal")
      end
    end
  end
end

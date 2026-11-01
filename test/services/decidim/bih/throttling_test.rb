# frozen_string_literal: true

require "test_helper"
require "ostruct"
require_relative "../../../../app/services/decidim/bih/throttling"

module Decidim
  module Bih
    # The one place a phone number becomes a rate-limit key. Both the host's
    # Rack::Attack rules and the engine's generated template call this, so the
    # two count the same citizen under the same key.
    class ThrottlingTest < Minitest::Test
      def setup
        @restore = stub_rails_application("test-secret-key-base")
      end

      def teardown
        @restore.call
      end

      def test_spacing_and_punctuation_cannot_buy_another_message
        assert_equal Decidim::Bih::Throttling.phone_key("+38765123456"),
                     Decidim::Bih::Throttling.phone_key(" +387 65/123-456 ")
      end

      def test_different_numbers_get_different_keys
        refute_equal Decidim::Bih::Throttling.phone_key("+38765123456"),
                     Decidim::Bih::Throttling.phone_key("+38765123457")
      end

      # A bare SHA-256 of a phone number is a lookup table away from being the
      # number itself: the whole BiH mobile space is ~10 million candidates.
      # The application secret is what makes the key useless to anyone who
      # gets a look at the throttle store.
      def test_the_digest_is_salted_with_the_application_secret
        first = Decidim::Bih::Throttling.phone_key("+38765123456")
        @restore.call
        @restore = stub_rails_application("a-different-secret")

        refute_equal first, Decidim::Bih::Throttling.phone_key("+38765123456")
        refute_includes first.to_s, "38765123456"
      end

      def test_nothing_to_count_returns_nil
        [nil, "", "   ", "abc", "()-"].each do |raw|
          assert_nil Decidim::Bih::Throttling.phone_key(raw), raw.inspect
        end
      end

      private

      # The helper salts with Rails.application.secret_key_base, so ::Rails
      # has to exist — and nothing provides it when this file runs on its own
      # rather than as part of the suite. A bare namespace is all it has to
      # be: actually requiring railties here would activate a second minitest
      # alongside the suite's own and leave the runner with nothing
      # registered to run.
      #
      # Defined per test and removed again on the way out, never once at load
      # time: a bare ::Rails left standing for the whole run answers
      # `defined?(Rails)` for every other file in the suite while answering
      # nothing else, which is a trap for any production guard written that
      # way (see Launch::InvitationWaves#issued_count).
      def stub_rails_application(secret)
        defined_here = !defined?(Rails)
        Object.const_set(:Rails, Module.new) if defined_here
        had_application = Rails.respond_to?(:application)
        original = Rails.method(:application) if had_application
        Rails.define_singleton_method(:application) { OpenStruct.new(secret_key_base: secret) }

        lambda do
          Rails.singleton_class.send(:remove_method, :application)
          Rails.define_singleton_method(:application, original) if had_application
          Object.send(:remove_const, :Rails) if defined_here
        end
      end
    end
  end
end

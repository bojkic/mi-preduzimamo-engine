# frozen_string_literal: true

require "test_helper"
require "digest"
require_relative "../../../../app/services/decidim/bih/sms_authorization"

module Decidim
  module Bih
    class SmsAuthorizationTest < Minitest::Test
      SECRET = "engine-test-secret"

      def test_normalize_keeps_only_plus_and_digits
        assert_equal "+38765123456", SmsAuthorization.normalize("+387 65/123-456")
        assert_equal "38765123456", SmsAuthorization.normalize("387 65 123 456")
        assert_equal "+06512345699", SmsAuthorization.normalize("+ 065 123 456 ext. 99")
        assert_equal "", SmsAuthorization.normalize(nil)
      end

      def test_normalize_is_idempotent
        raw = "+387 65 123-456"
        normalized = SmsAuthorization.normalize(raw)

        assert_equal normalized, SmsAuthorization.normalize(normalized)
      end

      def test_unique_id_matches_the_decidim_sms_formula_for_supported_phone_shapes
        with_secret(SECRET) do
          [
            "38765123456",
            "+38765123456",
            "065123456",
            "65123456",
            "+387 65 123-456",
            ""
          ].each do |phone|
            assert_equal legacy_unique_id(phone, SECRET),
                         SmsAuthorization.unique_id_for(phone),
                         "unique_id_for drifted for #{phone.inspect}"
          end
        end
      end

      def test_unique_id_preserves_the_leading_plus_as_part_of_the_canonical_recipe
        with_secret(SECRET) do
          assert_operator SmsAuthorization.unique_id_for("38765123456"),
                          :!=,
                          SmsAuthorization.unique_id_for("+38765123456")
        end
      end

      def test_phone_candidates_never_offer_a_blank_shape
        # A "+"-only input normalises to "+", whose digits-only shape is the
        # empty string. An empty shape identifies no phone at all, and
        # unique_id_candidates would still hash it into a lookup key that any
        # row written with a blank number would answer to — so it is dropped
        # here rather than at each of the four call sites.
        assert_equal ["+"], SmsAuthorization.phone_candidates("+")
        assert_empty SmsAuthorization.phone_candidates("  ")
        assert_empty SmsAuthorization.phone_candidates(nil)

        # The shapes a real number produces are untouched.
        assert_equal(
          ["+38765123456", "38765123456", "065123456"],
          SmsAuthorization.phone_candidates("+387 65 123-456")
        )
      end

      def test_unique_id_reads_the_current_rails_secret_key_base
        phone = "+387 65 123-456"

        with_secret("first-secret") do
          assert_equal legacy_unique_id(phone, "first-secret"), SmsAuthorization.unique_id_for(phone)
        end

        with_secret("second-secret") do
          assert_equal legacy_unique_id(phone, "second-secret"), SmsAuthorization.unique_id_for(phone)
        end
      end

      private

      def legacy_unique_id(phone, secret)
        Digest::SHA256.hexdigest("#{SmsAuthorization.normalize(phone)}-#{secret}")
      end

      def with_secret(secret)
        fake_application = Struct.new(:secret_key_base).new(secret)

        return with_existing_rails(fake_application) { yield } if Object.const_defined?(:Rails)

        with_temporary_rails(fake_application) { yield }
      end

      def with_existing_rails(fake_application)
        return Rails.stub(:application, fake_application) { yield } if Rails.respond_to?(:application)

        Rails.define_singleton_method(:application) { fake_application }
        yield
      ensure
        Rails.singleton_class.send(:remove_method, :application) if temporary_application_method?(fake_application)
      end

      def with_temporary_rails(fake_application)
        rails_module = Module.new
        rails_module.define_singleton_method(:application) { fake_application }
        Object.const_set(:Rails, rails_module)
        yield
      ensure
        Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails)
      end

      def temporary_application_method?(fake_application)
        Object.const_defined?(:Rails) &&
          Rails.respond_to?(:application) &&
          Rails.application.equal?(fake_application)
      end
    end
  end
end

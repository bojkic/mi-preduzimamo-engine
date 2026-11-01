# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/suppression_key"

module Decidim
  module Bih
    module Messaging
      # Destination IDENTITY is decided here, and getting it wrong is how one
      # person's hard bounce silences a different person. Two rules pull against
      # each other and both are load-bearing: normalize enough that the same
      # destination written two ways is one identity, and normalize no further,
      # because every collapse merges two people into one key.
      class SuppressionKeyTest < Minitest::Test
        def test_email_is_normalized_case_insensitively_and_trimmed
          assert_equal SuppressionKey.digest(kind: :email, value: " Ana@Example.ORG "),
                       SuppressionKey.digest(kind: :email, value: "ana@example.org")
        end

        # Gmail collapses these; most mail servers do not, and a suppression
        # store that guesses wrong silences an address nobody complained about.
        def test_email_plus_addressing_is_not_collapsed
          refute_equal SuppressionKey.digest(kind: :email, value: "ana+news@example.org"),
                       SuppressionKey.digest(kind: :email, value: "ana@example.org")
        end

        def test_phone_normalizes_to_digits_only
          assert_equal SuppressionKey.digest(kind: :phone, value: "+387 65 123-456"),
                       SuppressionKey.digest(kind: :phone, value: "+38765123456")
        end

        def test_different_kinds_never_collide
          refute_equal SuppressionKey.digest(kind: :phone, value: "38765123456"),
                       SuppressionKey.digest(kind: :email, value: "38765123456")
        end

        # An Infobip chat identity is opaque: it may look like a phone number and
        # not be one. Parsing it as a phone would let a Messenger id suppress a
        # real handset.
        def test_an_opaque_provider_identity_is_used_verbatim_not_parsed_as_a_phone
          refute_equal SuppressionKey.digest(kind: :channel_identity, value: "1234567890"),
                       SuppressionKey.digest(kind: :phone, value: "1234567890")
          assert_equal SuppressionKey.digest(kind: :channel_identity, value: "12 34567890"),
                       SuppressionKey.digest(kind: :channel_identity, value: "12 34567890")
          refute_equal SuppressionKey.digest(kind: :channel_identity, value: "12 34567890"),
                       SuppressionKey.digest(kind: :channel_identity, value: "1234567890")
        end

        def test_the_digest_is_sha256_hex_and_never_reversible
          digest = SuppressionKey.digest(kind: :email, value: "ana@example.org")

          assert_equal 64, digest.length
          assert_match(/\A[0-9a-f]{64}\z/, digest)
          refute_includes digest, "ana"
        end

        # The failure mode this prevents: a blank destination hashing to one
        # shared digest, so the first bounce with a missing address suppresses
        # every other record that also had none.
        def test_a_blank_destination_raises_rather_than_producing_a_shared_digest
          assert_raises(ArgumentError) { SuppressionKey.digest(kind: :email, value: "") }
          assert_raises(ArgumentError) { SuppressionKey.digest(kind: :email, value: nil) }
          assert_raises(ArgumentError) { SuppressionKey.digest(kind: :phone, value: "   ") }
          # A phone with no digits at all normalizes to nothing; that is blank.
          assert_raises(ArgumentError) { SuppressionKey.digest(kind: :phone, value: "++") }
        end

        def test_an_unknown_kind_raises_rather_than_being_hashed_as_an_opaque_string
          assert_raises(ArgumentError) { SuppressionKey.digest(kind: :astrology, value: "x") }
        end

        def test_normalize_returns_the_comparable_form_without_hashing_it
          assert_equal "ana@example.org", SuppressionKey.normalize(kind: :email, value: " Ana@Example.ORG ")
          assert_equal "38765123456", SuppressionKey.normalize(kind: :phone, value: "+387 65 123-456")
        end

        # A destination Hash is what the router and the producers already pass
        # around; accepting both shapes keeps callers from writing the splat.
        def test_a_destination_hash_is_accepted_in_place_of_keywords
          assert_equal SuppressionKey.digest(kind: :email, value: "ana@example.org"),
                       SuppressionKey.digest({ kind: :email, value: "ana@example.org" })
        end
      end
    end
  end
end

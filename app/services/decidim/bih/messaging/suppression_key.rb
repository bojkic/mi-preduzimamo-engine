# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Messaging
      # Destination IDENTITY: the one place that decides whether two written
      # forms of an address are the same destination.
      #
      # Every answer here is a trade between two failure modes. Normalize too
      # little and a citizen who bounced as "Ana@Example.org" keeps receiving
      # mail at "ana@example.org". Normalize too much and one person's refusal
      # silences somebody else — which is why plus-addressing is NOT collapsed
      # (most mail servers treat ana+news@ as a different mailbox) and why an
      # opaque provider identity is never parsed as a phone number even when it
      # is all digits.
      #
      # The digest is kind-scoped, so a phone and an e-mail that happen to be
      # written the same can never produce one key.
      #
      # Deliberately plain Ruby: no Rails, no ActiveSupport, no database. It is
      # loaded by the pure unit suite and by the suppression store alike.
      module SuppressionKey
        # `account` and `push_endpoint` are here because an attempt has to name
        # a destination kind even when the leg has no transport address of its
        # own: a bell is addressed to the account, a push to one device.
        KINDS = %w(phone email channel_identity push_endpoint account).freeze

        # Kinds whose written form carries formatting that means nothing.
        DIGITS_ONLY_KINDS = %w(phone).freeze
        CASE_INSENSITIVE_KINDS = %w(email).freeze

        module_function

        # Accepts either keywords or the destination Hash callers already pass.
        def normalize(destination = nil, kind: nil, value: nil)
          kind, value = unwrap(destination, kind, value)
          kind = kind.to_s
          raise ArgumentError, "unknown destination kind #{kind.inspect}" unless KINDS.include?(kind)

          normalized = normalize_value(kind, value)
          raise ArgumentError, "destination value required for #{kind}" if normalized.empty?

          normalized
        end

        def digest(destination = nil, kind: nil, value: nil)
          kind, value = unwrap(destination, kind, value)
          normalized = normalize(kind: kind, value: value)
          # The kind is inside the hashed string, not merely beside it: two
          # digests can then never be compared across kinds by accident.
          Digest::SHA256.hexdigest("#{kind}\0#{normalized}")
        end

        def unwrap(destination, kind, value)
          return [kind, value] if destination.nil?
          raise ArgumentError, "destination must be a Hash" unless destination.respond_to?(:[])

          [destination[:kind] || destination["kind"], destination[:value] || destination["value"]]
        end

        def normalize_value(kind, value)
          text = value.to_s
          return text.gsub(/[^0-9]/, "") if DIGITS_ONLY_KINDS.include?(kind)
          return text.strip.downcase if CASE_INSENSITIVE_KINDS.include?(kind)

          # Opaque by contract. Trimmed only, never reformatted: an Infobip
          # chat id, a device fingerprint and an account reference are given to
          # us and mean exactly what they say.
          text.strip
        end
      end
    end
  end
end

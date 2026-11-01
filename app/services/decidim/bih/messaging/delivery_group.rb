# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # One INDEPENDENT delivery group of a routing plan.
      #
      # Independence is the whole point: two groups in the same plan never
      # cancel each other. A bell that succeeds does not end a phone chain, a
      # phone chain that fails does not suppress the report e-mail, and one dead
      # push endpoint does not cause a resend to the other devices.
      # `terminates_siblings` is a data member rather than a comment so the
      # invariant is visible in an artifact, and it is always false.
      #
      # Everything here is copied out of the Phase 1 registry group
      # (`MessageClass.group`) rather than re-decided, except `attempt_strategy`
      # and `channels`, which the router derives.
      #
      # Plain Ruby: loaded by the pure unit suite, no Rails.
      DeliveryGroup = Struct.new(
        :name, # String, unique within the plan
        :channels, # Array<String>, ordered, already policy-filtered
        :legs, # Array<Hash> for per-device fanout; [] otherwise
        :group_mode, # String: fallback | parallel | single (registry verbatim)
        :fanout, # String: per_recipient | per_device (registry verbatim)
        :attempt_strategy, # Symbol: :single_request | :sequential | :parallel
        :content_variant, # String, the group default
        :content_variant_by_channel, # Hash<String,String>; WhatsApp report copy is NOT Viber report copy
        :locale, # String
        :template, # Hash or nil, exactly as the host resolver returned it
        :expires_at, # Time; earliest of class ttl, caller deadline and decision expiry
        :dedup_identity, # String, unique per organization + business event + group
        :dedup_owner, # String, registry `deduplication`
        :timeout_policy, # Symbol; :uncertain_no_retry — a timeout is never a retry instruction
        :fallback_owner, # String: none | producer | provider
        :terminates_siblings, # always false
        :priority, # String: authentication | transactional | routine | bulk
        :preference_adapter, # String, the permission contract that governed this group
        :reason_codes, # Array<Symbol> carried from the permitting Decisions
        keyword_init: true
      ) do
        # Every leg attempted, none conditional on another.
        def parallel? = attempt_strategy == :parallel

        # One provider request carrying the whole channel list; the provider (or
        # the linked session) owns any failover inside it and the router never
        # advances a channel itself.
        def single_request? = attempt_strategy == :single_request

        # The router tries channels in order and advances ONLY on a definitive
        # rejection.
        def sequential? = attempt_strategy == :sequential

        def per_device? = fanout.to_s == "per_device"

        # D8 expresses quiet hours as a `routine`-only deferral. Task 2.7
        # activates it; this predicate only makes the class computable.
        def quiet_hours_deferrable? = priority.to_s == "routine"

        def content_variant_for(channel)
          (content_variant_by_channel || {})[channel.to_s] || content_variant
        end

        # Recipient-free summary, for comparison artifacts and diagnostics.
        def delivery_signature
          { name:, channels:, content_variant:, locale:, priority:,
            attempt_strategy:, legs: legs.size }
        end

        def frozen_copy
          self.channels = channels.freeze
          self.legs = legs.map(&:freeze).freeze
          self.reason_codes = reason_codes.freeze
          self.content_variant_by_channel = (content_variant_by_channel || {}).freeze
          freeze
        end
      end
    end
  end
end

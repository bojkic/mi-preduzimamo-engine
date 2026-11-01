# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # An immutable, ordered set of independent delivery groups, plus an
      # explicit record of everything that was NOT sent and why.
      #
      # `suppressed` is not an error list. It is the honest other half of the
      # plan: a channel a preference blocked, a channel the caller did not ask
      # for, a channel a `single` group did not select, a payload that expired.
      # A routing decision that drops a channel without a reason code is the
      # failure mode this object exists to make impossible.
      #
      # Plain Ruby: loaded by the pure unit suite, no Rails.
      RoutingPlan = Struct.new(
        :message_class_key,
        :recipient_ref, # opaque; NEVER a phone number, e-mail or endpoint
        :mode, # Symbol: :legacy | :compatibility | :target
        :groups, # Array<DeliveryGroup>
        :suppressed, # Array<Hash> { group:, channel:, reason_codes:, policy_version:, eligibility_version: }
        :policy_version,
        :eligibility_version,
        :created_at,
        keyword_init: true
      ) do
        def empty? = groups.empty?

        def deliverable? = !groups.empty?

        def channels = groups.flat_map(&:channels).uniq

        def group(name) = groups.find { |candidate| candidate.name == name.to_s }

        def suppressed_reasons = suppressed.flat_map { |entry| entry[:reason_codes] }.uniq

        # D6 activation is all-at-once, so the question "would the whole base
        # receive the same set under the other mode?" has to be answerable by
        # comparing two of these. Deterministic, ordered and recipient-free.
        def delivery_set
          {
            message_class: message_class_key,
            groups: groups.map(&:delivery_signature),
            suppressed: suppressed.map { |entry| { group: entry[:group], channel: entry[:channel], reason_codes: entry[:reason_codes] } }
          }
        end

        # Aggregate-safe: deliberately WITHOUT `recipient_ref`, so a plan can be
        # logged or exported without carrying a per-citizen identifier.
        def to_h
          {
            message_class: message_class_key,
            mode:,
            policy_version:,
            eligibility_version:,
            created_at:,
            groups: groups.map(&:delivery_signature),
            suppressed: suppressed.map { |entry| { group: entry[:group], channel: entry[:channel], reason_codes: entry[:reason_codes] } }
          }
        end

        def frozen_copy
          self.groups = groups.each(&:frozen_copy).freeze
          self.suppressed = suppressed.map(&:freeze).freeze
          freeze
        end
      end
    end
  end
end

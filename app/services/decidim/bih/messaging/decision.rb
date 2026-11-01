# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The answer to one question: may THIS message class reach THIS recipient
      # on THIS channel, right now, under THIS mode — and why.
      #
      # It is a value object on purpose. Building one performs no write, no
      # enqueue, no token creation and no provider call, so a shadow evaluation
      # can never become a send by accident. `reason_codes` are a classified
      # list rather than prose, because Task 1.6 has to aggregate them.
      class Decision
        ATTRIBUTES = [
          :permitted, :reason_codes, :preference_origin, :policy_version, :eligibility_version, :expires_at, :mode, :message_class, :channel, :channel_group
        ].freeze

        attr_reader(*ATTRIBUTES)

        # rubocop:disable Metrics/ParameterLists
        def initialize(permitted:, message_class:, channel:, mode:, policy_version:, eligibility_version:,
                       reason_codes: [], preference_origin: "absent", expires_at: nil, channel_group: nil)
          @permitted = permitted
          @message_class = message_class
          @channel = channel
          @mode = mode
          @policy_version = policy_version
          @eligibility_version = eligibility_version
          @reason_codes = Array(reason_codes).map(&:to_sym).uniq.freeze
          @preference_origin = preference_origin
          @expires_at = expires_at
          @channel_group = channel_group
          freeze
        end
        # rubocop:enable Metrics/ParameterLists

        def permitted?
          permitted == true
        end

        def denied?
          !permitted?
        end

        # Deliberately free of identifiers: this is what a comparison artifact,
        # a diagnostic log or an aggregate report may keep.
        def to_h
          {
            permitted:,
            message_class:,
            channel:,
            channel_group:,
            mode:,
            reason_codes: reason_codes.map(&:to_s),
            preference_origin:,
            policy_version:,
            eligibility_version:,
            expires_at: expires_at&.iso8601
          }
        end

        def ==(other)
          other.is_a?(Decision) && to_h == other.to_h
        end
        alias eql? ==

        def hash
          to_h.hash
        end
      end
    end
  end
end

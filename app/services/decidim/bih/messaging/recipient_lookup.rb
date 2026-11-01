# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # What an authorized operator may see about ONE delivery leg while working
      # a case, and nothing beyond it.
      #
      # The rule this class exists to hold: an operator working a report case
      # legitimately needs to know whether the citizen's copy went out and what
      # happened to it. They do not need — and must never be handed — the phone
      # number, the e-mail address, the push endpoint, the message body or the
      # digest that would let them look any of those up elsewhere.
      #
      # So the answer is a fixed, small shape: channel, outcome, reason, when it
      # was observed, and what KIND of destination it was. A digest is deliberately
      # absent: it is not an address, but it is a stable per-person identifier,
      # and handing it out turns an operator screen into a correlation tool.
      module RecipientLookup
        # `Decidim::ActionForbidden` is the house refusal — six engine services
        # already raise it — so this raises it too rather than inventing a
        # seventh. Worth knowing: the constant is created inside
        # `Decidim::NeedsPermission`'s `included do` (decidim-core 0.31.7,
        # needs_permission.rb:14), so it exists once a controller has included
        # that concern. Every caller of this module is a controller.
        #
        # Reading a delivery leg is reading case correspondence metadata, so it
        # is gated on the same permission as reading the case itself. It is NOT
        # gated on `operations_read`, which almost every operator role carries.
        PERMISSION = :reports_read
        FIELDS = [:channel, :channel_group, :outcome, :reason, :observed_at, :destination_kind].freeze

        module_function

        def for_operator(attempt:, operator:)
          organization = attempt&.intent&.organization
          raise Decidim::ActionForbidden, "unknown attempt" if organization.nil?
          raise Decidim::ActionForbidden, "operator may not read case correspondence" unless
            OperatorAuthorization.allowed?(operator, PERMISSION, organization:)

          {
            channel: attempt.channel,
            channel_group: attempt.channel_group,
            outcome: attempt.status,
            reason: attempt.reason,
            observed_at: attempt.settled_at || attempt.claimed_at,
            destination_kind: attempt.destination_kind
          }
        end

        # The same shape for a whole intent, for the case screen. Still one row
        # per leg, still no destination.
        def legs_for_operator(intent:, operator:)
          intent.attempts.order(:id).map { |attempt| for_operator(attempt:, operator:) }
        end
      end
    end
  end
end

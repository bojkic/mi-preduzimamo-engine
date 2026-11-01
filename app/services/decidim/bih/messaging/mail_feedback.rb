# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Mail bounce/complaint ingestion is deliberately unavailable until an
      # authenticated provider feed and reviewed payload contract are configured.
      # A monitored reply mailbox is not evidence of automated bounce coverage.
      # Suppression and reply handling remain separate operator responsibilities.
      module MailFeedback
        FeedbackNotConfigured = Class.new(TransportSuppression::FeedbackNotConfigured)

        PROVIDER = "mailbox"
        CHANNEL = "email"
        # How a provider's own words map onto the five reasons this platform
        # keeps apart. Populated when a feed is actually contracted; empty
        # because no feed is.
        EVENT_REASONS = {}.freeze

        module_function

        # There is no environment variable to set here yet ON PURPOSE. Adding
        # one before a provider contract exists would let an operator switch on
        # a code path that has never seen a real payload.
        def configured?
          false
        end

        def ingest!(payload:, organization:)
          raise FeedbackNotConfigured, "mail feedback ingestion has no contracted provider feed" unless configured?

          # Unreachable until `configured?` can answer true, and written out so
          # the shape a feed has to produce is reviewable rather than imagined.
          TransportSuppression.ingest!(
            organization:, provider: PROVIDER, channel: CHANNEL,
            destination: { kind: :email, value: payload.fetch("recipient") },
            reason: EVENT_REASONS.fetch(payload.fetch("event")),
            source: "mail_feedback", event_ref: payload["event_id"],
            occurred_at: payload["occurred_at"]
          )
        end
      end
    end
  end
end

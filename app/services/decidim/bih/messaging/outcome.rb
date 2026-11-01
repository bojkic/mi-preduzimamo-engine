# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The one vocabulary for "what happened to a delivery leg".
      #
      # The single load-bearing rule: ONLY {REJECTED} authorizes the next
      # channel in a group. Anything uncertain STOPS the chain, because a second
      # attempt after an unknown outcome is how one message becomes two paid
      # messages — Infobip may have taken the whole Viber→WhatsApp chain before
      # the socket gave up (see Infobip::Error#definitive_rejection?).
      #
      # The words are Phase 1's, not new ones. `:uncertain` is spelled the way
      # `Messaging::Attempt` spells it so a routed dispatch can record itself in
      # the Phase 1 ledger without a translation nobody remembers; {UNKNOWN} is
      # an alias for readers coming from the plan's wording, not a second state.
      # {attempt_status} is the mapping to `Attempt::STATUSES`, which has no
      # `rejected` of its own.
      #
      # Deliberately plain Ruby: no Rails, no ActiveSupport. It is loaded by the
      # pure unit suite and must not be able to reach a database or a provider.
      module Outcome
        QUEUED = :queued
        CLAIMED = :claimed
        ACCEPTED = :accepted # provider took the request / SMTP accepted
        DELIVERED = :delivered # explicit handset/delivery report
        REJECTED = :rejected # definitive; this send will never succeed
        UNCERTAIN = :uncertain # timeout, 5xx, missing id, worker died
        UNKNOWN = UNCERTAIN # alias; NOT a distinct outcome
        SKIPPED = :skipped # policy said no; nothing was sent
        EXPIRED = :expired # useful lifetime passed before sending
        FAILED = :failed # local failure before any provider contact

        ALL = [QUEUED, CLAIMED, ACCEPTED, DELIVERED, REJECTED, UNCERTAIN, SKIPPED, EXPIRED, FAILED].freeze

        # "Will not change by itself." An uncertain outcome is NOT terminal: it
        # is waiting for reconciliation.
        TERMINAL = [DELIVERED, REJECTED, SKIPPED, EXPIRED, FAILED].freeze

        # Higher wins in {merge}. The ordering encodes two safety rules:
        # uncertainty outranks any claim that nothing was sent, and a provider
        # acceptance is never downgraded to "skipped" by a later partial read.
        RANK = {
          QUEUED => 0,
          CLAIMED => 1,
          SKIPPED => 2,
          EXPIRED => 2,
          FAILED => 2,
          UNCERTAIN => 3,
          ACCEPTED => 4,
          REJECTED => 5,
          DELIVERED => 6
        }.freeze

        # Attempt has no `rejected`: a definitive provider refusal is recorded
        # as a failed attempt, with the provider's own reason code alongside it.
        ATTEMPT_STATUS = {
          QUEUED => "queued",
          CLAIMED => "claimed",
          ACCEPTED => "accepted",
          DELIVERED => "delivered",
          REJECTED => "failed",
          UNCERTAIN => "uncertain",
          SKIPPED => "skipped",
          EXPIRED => "expired",
          FAILED => "failed"
        }.freeze

        DELIVERED_REPORT_NAME = "DELIVERED_TO_HANDSET"
        REJECTED_REPORT_GROUPS = %w(REJECTED UNDELIVERABLE).freeze
        EXPIRED_REPORT_GROUP = "EXPIRED"

        module_function

        def authorizes_fallback?(outcome)
          return false if outcome.nil?

          outcome.to_sym == REJECTED
        end

        # `error` only has to answer `definitive_rejection?`; Infobip::Error is
        # the implementation today, and a second provider is not required to
        # become one to be classified.
        def classify(error: nil, response: nil, report: nil, previous: nil)
          return error.definitive_rejection? ? REJECTED : UNCERTAIN if error
          return classify_report(report, previous) if report
          return UNCERTAIN if response.nil?

          message_ids(response).empty? ? UNCERTAIN : ACCEPTED
        end

        def classify_report(report, previous = nil)
          status = at(report, "status") || {}
          name = at(status, "name") || at(report, "name")
          group = at(status, "groupName").to_s

          return DELIVERED if name.to_s == DELIVERED_REPORT_NAME
          return REJECTED if REJECTED_REPORT_GROUPS.include?(group)
          return EXPIRED if group == EXPIRED_REPORT_GROUP

          previous || ACCEPTED
        end

        # Provider payloads arrive as String-keyed JSON, tests and callers
        # sometimes hand over Symbol keys. Neither is worth a branch per read.
        def at(hash, key)
          return nil unless hash.respond_to?(:[])

          hash[key] || hash[key.to_sym]
        end

        def message_ids(response)
          return [] unless response.respond_to?(:[])

          Array(at(response, "messages")).filter_map do |message|
            id = at(message, "messageId").to_s
            id.empty? ? nil : id
          end
        end

        # A terminal record is never silently reset by a rollback or a later
        # partial observation. Merge keeps the stronger claim.
        def merge(current, candidate)
          return candidate&.to_sym if current.nil?
          return current.to_sym if candidate.nil?

          RANK.fetch(current.to_sym, -1) >= RANK.fetch(candidate.to_sym, -1) ? current.to_sym : candidate.to_sym
        end

        def attempt_status(outcome)
          ATTEMPT_STATUS.fetch(outcome.to_sym)
        end
      end
    end
  end
end

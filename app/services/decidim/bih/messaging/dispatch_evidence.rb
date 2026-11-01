# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Messaging
      # The minimum intent/attempt correlation an enrolled sender needs before
      # Phase 2 is allowed to send through it.
      #
      # Two rules, and they point in opposite directions on purpose:
      #
      #   * A ledger write failure BEFORE the claim must prevent the send. If we
      #     cannot record that we are about to do something billable, we do not
      #     do it — an unrecorded paid send is the one outcome nobody can
      #     reconcile afterwards.
      #   * A logging failure AFTER the provider call must NOT become a retry.
      #     The work may already have happened, so the attempt becomes
      #     `uncertain` and waits for reconciliation. "We lost the receipt" is
      #     never an instruction to send again.
      #
      # Nothing here stores a payload. Authentication codes, magic links, report
      # tokens and push endpoints stay in their own purpose-bound, short-lived
      # stores and are never duplicated into a general ledger.
      module DispatchEvidence
        class LedgerUnavailable < StandardError; end

        Outcome = Struct.new(:attempt, :status, :error, keyword_init: true) do
          def uncertain?
            status == "uncertain"
          end
        end

        module_function

        # rubocop:disable Metrics/ParameterLists
        def record_intent!(organization:, message_class:, recipient:, decision:, correlation_key:,
                           deduplication_scope:, account_notification: nil, expires_at: nil)
          entry = MessageClass.fetch(message_class)
          user = recipient.account_lookup_allowed? ? Decidim::User.find_by(id: recipient.account_id) : nil

          Intent.create!(
            organization:, message_class: entry.key, recipient_kind: recipient.kind, user:,
            recipient_reference: safe_reference(recipient),
            correlation_key:, deduplication_scope:,
            policy_version: decision.policy_version, eligibility_version: decision.eligibility_version,
            mode: decision.mode == Modes::LEGACY ? "shadow" : decision.mode,
            status: "evaluated", reason_codes: decision.reason_codes.map(&:to_s),
            context_digest: context_digest(recipient), expires_at: expires_at || decision.expires_at,
            account_notification:
          )
        rescue ActiveRecord::ActiveRecordError => e
          raise LedgerUnavailable, "cannot record intent (#{e.class})"
        end
        # rubocop:enable Metrics/ParameterLists

        # The claim is committed before the block runs. If the claim cannot be
        # written, the block never runs — that is the whole point.
        # `destination` is `{ kind:, digest: }` or `{ kind:, value: }`. The value
        # form is hashed here and never stored; the digest form lets a caller
        # that already normalized its destination keep the raw one out of the
        # router entirely.
        def with_claim(intent:, channel_group:, channel:, destination_version: nil, destination: nil)
          attempt = begin
            intent.attempts.create!(channel_group:, channel:, destination_version:,
                                    destination_kind: Correlation.destination_kind(destination),
                                    destination_digest: Correlation.destination_digest(destination),
                                    status: "claimed", claimed_at: Time.current)
          rescue ActiveRecord::ActiveRecordError => e
            raise LedgerUnavailable, "cannot claim attempt (#{e.class})"
          end

          begin
            result = yield(attempt)
            settle(attempt, status: "accepted", provider_message_id: provider_id(result))
            Outcome.new(attempt:, status: attempt.status, error: nil)
          rescue StandardError => e
            # The provider may already have done the work. Uncertain, never a
            # retry instruction.
            settle(attempt, status: "uncertain", reason: e.class.name)
            Outcome.new(attempt:, status: "uncertain", error: e)
          end
        end

        # Statuses that will not change by themselves. `uncertain` is NOT here:
        # it is waiting for reconciliation, which is exactly why it must never
        # be reset to pending to tidy a dashboard.
        #
        # ⚠️ FULLY QUALIFIED on purpose. `Outcome` inside this module resolves to
        # the local `Outcome` Struct three lines up, NOT to the vocabulary — and
        # the failure is invisible: the NameError happens while the file loads,
        # and `AccountNotifications#routed_dispatch!` rescues StandardError, so
        # the routed path would silently settle every intent "unknown" instead
        # of crashing where somebody would notice.
        TERMINAL_STATUSES = Decidim::Bih::Messaging::Outcome::TERMINAL
                            .map { |outcome| Decidim::Bih::Messaging::Outcome.attempt_status(outcome) }.uniq.freeze
        ACCEPTANCE_STATUSES = Decidim::Bih::Messaging::Attempt::ACCEPTANCE_PROVING
                              .map { |outcome| Decidim::Bih::Messaging::Outcome.attempt_status(outcome) }.freeze

        # rubocop:disable Metrics/ParameterLists
        def settle(attempt, status:, reason: nil, provider_message_id: nil, provider_message_ids: nil, at: nil)
          at ||= Time.current
          ids = normalized_ids(provider_message_ids, provider_message_id)
          updates = { status:, reason:, provider_message_id: provider_message_id || ids.first, settled_at: at }
          # One provider-managed chain answers with one id PER CHANNEL. Union,
          # never assignment: a later settle must not drop an id a delivery
          # report will arrive for.
          updates[:provider_message_ids] = (Array(attempt.provider_message_ids) | ids) if ids.any?
          updates[:accepted_at] = at if attempt.accepted_at.nil? && ACCEPTANCE_STATUSES.include?(status.to_s)
          updates[:resolved_at] = at if attempt.resolved_at.nil? && TERMINAL_STATUSES.include?(status.to_s)
          attempt.update!(updates)
          attempt
        rescue ActiveRecord::ActiveRecordError
          # A post-provider logging failure leaves the attempt where it is. It
          # is deliberately swallowed: raising here would look like a failed
          # send to the caller and invite a duplicate.
          attempt
        end
        # rubocop:enable Metrics/ParameterLists

        def normalized_ids(provider_message_ids, provider_message_id)
          ids = Array(provider_message_ids).map(&:to_s).reject(&:empty?)
          return ids if ids.any?

          Array(provider_message_id).compact.map(&:to_s).reject(&:empty?)
        end

        # Correlation gaps, stuck claims and uncertain outcomes, as aggregate
        # counts an operator can act on. No recipient detail.
        def diagnostics(organization:, since: 24.hours.ago)
          intents = Intent.where(organization:).where(created_at: since..)
          attempts = Attempt.where(intent_id: intents.select(:id))
          {
            intents: intents.count,
            intents_without_attempt: intents.where.not(id: attempts.select(:intent_id)).count,
            attempts: attempts.count,
            by_status: attempts.group(:status).count,
            stuck_claims: attempts.where(status: "claimed").where(claimed_at: ...30.minutes.ago).count,
            uncertain: attempts.where(status: "uncertain").count,
            expired: intents.where.not(expires_at: nil).where(expires_at: ...Time.current).count
          }
        end

        def safe_reference(recipient)
          return nil if recipient.account_lookup_allowed?
          return recipient.identity_digest if recipient.identity_digest

          Digest::SHA256.hexdigest("recipient:#{recipient.kind}:#{recipient.destination}")
        end

        def context_digest(recipient)
          Digest::SHA256.hexdigest(recipient.to_h.sort.to_s)
        end

        def provider_id(result)
          return nil unless result.is_a?(Hash)

          result["messageId"] || result[:message_id]
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Attaches an existing producer's record to an intent WITHOUT moving it.
      #
      # `decidim_notifications` rows, push subscriptions, mail and provider legs
      # all keep their own storage, their own retention and their own callers;
      # what they gain is a link and one attempt row per real delivery leg.
      # Nothing here reads or copies a message body, a token, a magic link or a
      # push endpoint URL.
      #
      # ── The ledger-failure rule is TWO rules, and this module is where the
      # second one lives ───────────────────────────────────────────────────────
      #
      # Phase 1's rule — a ledger write failure BEFORE the claim must prevent
      # the send — was written for the enrolled, BILLABLE external copy, and it
      # stays exactly as it is in {DispatchEvidence}: an unrecorded paid send is
      # the one outcome nobody can reconcile afterwards.
      #
      # The legs this module adds are free and in-platform: a bell row, a
      # browser push, an SMTP hand-off. Applying the same rule to those would
      # mean a failed INSERT suppresses a citizen's case notification — trading
      # a missing observation for a missing notification, which is the wrong
      # direction. So every entry point here is observational: it rescues, logs
      # the error class only, returns nil, and the gap shows up as a correlation
      # gap in {Reconciliation} rather than as a silently dropped message.
      #
      # {claim!} is the exception and is named for it: it raises, and it is for
      # callers that must not proceed without a ledger row.
      module Correlation
        OBSERVED_REASON_CODES = [:legacy_observed].freeze
        # A correlated legacy leg is observed, not authorized: the producer
        # decided, and this row records what it did. `shadow` is the intent mode
        # that means exactly that.
        OBSERVED_MODE = "shadow"

        module_function

        # One intent for one business event, found before it is created.
        #
        # The ledger's unique index is (organization, deduplication_scope,
        # correlation_key); a lost race means somebody else recorded the same
        # event, so the loser reads the winner's row rather than failing.
        # rubocop:disable Metrics/ParameterLists
        def intent_for(organization:, message_class:, recipient:, correlation_key:,
                       deduplication_scope: nil, account_notification: nil, expires_at: nil,
                       status: "recorded")
          raise ArgumentError, "unknown message class #{message_class.inspect}" unless MessageClass.known?(message_class.to_s)

          scope = (deduplication_scope || default_scope(message_class)).to_s
          find_intent(organization:, scope:, correlation_key:) ||
            create_intent(organization:, message_class:, recipient:, correlation_key:, scope:,
                          account_notification:, expires_at:, status:)
        rescue ActiveRecord::RecordNotUnique
          find_intent(organization:, scope: (deduplication_scope || default_scope(message_class)).to_s,
                      correlation_key:)
        rescue ActiveRecord::ActiveRecordError => e
          log("intent #{message_class}", e)
          nil
        end
        # rubocop:enable Metrics/ParameterLists

        # Record one real delivery leg. Never raises; returns the Attempt or nil.
        #
        # `leg_ref` is BOTH the per-device reference and the idempotency key: a
        # caller that supplies one gets the same row back on a retry, a caller
        # that does not gets a new row per call, because a resend genuinely is a
        # second leg.
        # rubocop:disable Metrics/ParameterLists
        def record!(intent:, group:, channel:, outcome:, reason: nil, destination: nil,
                    leg_ref: nil, provider_message_ids: nil, at: Time.current)
          return nil if intent.nil?

          attempt = attempt_for(intent:, group:, channel:, destination:, leg_ref:, at:)
          return nil if attempt.nil?

          attempt.observe!(outcome:, reason:, provider_message_ids:, at:)
        rescue ActiveRecord::ActiveRecordError => e
          log("attempt #{group}/#{channel}", e)
          nil
        end
        # rubocop:enable Metrics/ParameterLists

        # The whole correlation in one call, for producers that have no intent
        # yet. Observational: a ledger failure never reaches the caller.
        # rubocop:disable Metrics/ParameterLists
        def observe!(organization:, message_class:, recipient:, correlation_key:, group:, channel:,
                     outcome:, reason: nil, destination: nil, leg_ref: nil,
                     deduplication_scope: nil, provider_message_ids: nil, expires_at: nil, at: Time.current)
          intent = intent_for(organization:, message_class:, recipient:, correlation_key:,
                              deduplication_scope:, expires_at:)
          record!(intent:, group:, channel:, outcome:, reason:, destination:, leg_ref:,
                  provider_message_ids:, at:)
        end
        # rubocop:enable Metrics/ParameterLists

        # The strict variant, for a caller that must not send without a ledger
        # row. Raises LedgerUnavailable exactly as Phase 1 does.
        # rubocop:disable Metrics/ParameterLists
        def claim!(intent:, group:, channel:, destination: nil, leg_ref: nil, at: Time.current)
          build_attempt(intent:, group:, channel:, destination:, leg_ref:, at:)
        rescue ActiveRecord::ActiveRecordError => e
          raise DispatchEvidence::LedgerUnavailable, "cannot claim attempt (#{e.class})"
        end

        # ---- internals -------------------------------------------------------

        def find_intent(organization:, scope:, correlation_key:)
          Intent.find_by(organization:, deduplication_scope: scope, correlation_key: correlation_key.to_s)
        end

        def create_intent(organization:, message_class:, recipient:, correlation_key:, scope:,
                          account_notification:, expires_at:, status:)
          entry = MessageClass.fetch(message_class.to_s)
          Intent.create!(
            organization:, message_class: entry.key, recipient_kind: recipient.kind,
            user: intent_user(recipient:, organization:),
            recipient_reference: DispatchEvidence.safe_reference(recipient),
            correlation_key: correlation_key.to_s, deduplication_scope: scope,
            policy_version: Policy::POLICY_VERSION, eligibility_version: Policy::ELIGIBILITY_VERSION,
            mode: OBSERVED_MODE, status:, reason_codes: OBSERVED_REASON_CODES.map(&:to_s),
            context_digest: DispatchEvidence.context_digest(recipient),
            expires_at:, account_notification:
          )
        end

        def intent_user(recipient:, organization:)
          return nil unless recipient.account_lookup_allowed?

          Decidim::User.where(id: recipient.account_id, decidim_organization_id: organization&.id).first
        end

        def attempt_for(intent:, group:, channel:, destination:, leg_ref:, at:)
          existing = leg_ref && intent.attempts.find_by(channel_group: group.to_s, channel: channel.to_s,
                                                        destination_version: leg_ref.to_s)
          existing || build_attempt(intent:, group:, channel:, destination:, leg_ref:, at:)
        end

        def build_attempt(intent:, group:, channel:, destination:, leg_ref:, at:)
          intent.attempts.create!(
            channel_group: group.to_s, channel: channel.to_s,
            destination_version: leg_ref&.to_s,
            destination_kind: destination_kind(destination),
            destination_digest: destination_digest(destination),
            status: Outcome.attempt_status(Outcome::CLAIMED), claimed_at: at
          )
        end
        # rubocop:enable Metrics/ParameterLists

        def destination_kind(destination)
          return nil if destination.nil?

          (destination[:kind] || destination["kind"])&.to_s
        end

        # A destination without a value is a destination we do not have; it is
        # recorded as a kind with no digest rather than hashed into a shared
        # placeholder that would make unrelated legs look like one identity.
        #
        # A caller that has already normalized may pass `digest:` instead of
        # `value:`, which keeps the raw destination out of the router.
        def destination_digest(destination)
          return nil if destination.nil?

          precomputed = destination[:digest] || destination["digest"]
          return precomputed.to_s if precomputed.to_s.length == 64

          value = destination[:value] || destination["value"]
          return nil if value.to_s.strip.empty?

          SuppressionKey.digest(kind: destination_kind(destination), value:)
        rescue ArgumentError
          nil
        end

        def default_scope(message_class)
          "#{message_class}:observed"
        end

        # The error CLASS only. A correlation log line must never be able to
        # carry an address, a token or a message body.
        def log(what, error)
          Rails.logger.warn("[messaging] correlation #{what}: #{error.class}")
        end
      end
    end
  end
end

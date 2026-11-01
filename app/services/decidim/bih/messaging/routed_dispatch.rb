# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Executes ONE group of a RoutingPlan: claim, recheck, send, classify.
      #
      # Modelled on the proven shape in `AccountNotifications.dispatch!`
      # (claim inside a lock, COMMIT the claim, then perform the irreversible
      # send) and built on Phase 1's `DispatchEvidence.with_claim`, which
      # already guarantees the two halves of that rule:
      #
      #   * a ledger write failure BEFORE the claim raises `LedgerUnavailable`
      #     and the transport is never called;
      #   * a logging failure AFTER the provider call is never a retry.
      #
      # What this class adds is classification. `with_claim` can only settle
      # "accepted" or "uncertain"; the router needs the finer answer — a
      # response with no message id is uncertain, not accepted, and a definitive
      # 4xx is a rejection, not an unknown — so each attempt is re-settled with
      # `Outcome.attempt_status`.
      #
      # Three rules it enforces, and none of them is negotiable:
      #
      #   1. ONLY a definitive rejection advances a sequential group. A timeout,
      #      a 5xx, a missing message id — anything uncertain STOPS it. A second
      #      attempt after an unknown outcome is how one message becomes two
      #      paid messages.
      #   2. A parallel group attempts EVERY leg, and one failed endpoint never
      #      causes a resend to the others and never causes a fallback.
      #   3. A provider-owned chain is ONE request carrying the whole channel
      #      list. The router never advances a channel the provider already owns.
      #
      # Groups are independent: this class executes one group and knows nothing
      # about its siblings, so it structurally cannot let a successful bell
      # terminate a phone chain.
      class RoutedDispatch
        Result = Struct.new(
          :group, :channel, :channels, :endpoint_ref, :outcome, :provider_ids, :reason,
          keyword_init: true
        )

        DEFAULT_STOP_REASON = "policy_refused"
        REPLAYED_REASON = "already_attempted"

        # Attempt statuses that prove the transport may already have been
        # reached for this leg. `claimed` is in the list on purpose: a committed
        # claim with no settlement is a worker that died between the two, and we
        # do not know whether the provider was paid. `queued`, `skipped` and
        # `expired` are NOT here — for those the transport was provably never
        # called, so a retry may legitimately try again.
        SPENT_ATTEMPT_STATUSES = %w(claimed accepted delivered uncertain failed).freeze

        # How a replayed attempt's ledger status reads back as an outcome. The
        # ledger cannot say whether a `failed` leg was a DEFINITIVE provider
        # rejection, and `Outcome::FAILED` does not authorize a fallback — which
        # is the safe direction: "only a definitive rejection advances a chain",
        # and a row that cannot prove definitiveness is not one.
        REPLAYED_OUTCOMES = {
          "claimed" => Outcome::UNCERTAIN,
          "accepted" => Outcome::ACCEPTED,
          "delivered" => Outcome::DELIVERED,
          "uncertain" => Outcome::UNCERTAIN,
          "failed" => Outcome::FAILED
        }.freeze

        # @param group [DeliveryGroup] one group of a frozen RoutingPlan
        # @param intent [Messaging::Intent] the Phase 1 parent-intent row
        # @param transport [#call] `call(channel:, channels:, group:, leg:)`
        # @param policy_recheck [#call, nil] `call(channel:)` -> anything answering
        #   `permitted?` and `reason_codes`; evaluated INSIDE the claim, immediately
        #   before the irreversible send
        # @param ledger [#with_claim, #settle] defaults to Phase 1's DispatchEvidence
        # @param destinations [#call, nil] `call(channel:, leg:)` -> `{ kind:, digest: }`
        #   for the leg being attempted. It answers with a DIGEST, not an
        #   address: the router never needs the raw destination and must not be
        #   the place a phone number starts travelling.
        # rubocop:disable Metrics/ParameterLists
        def initialize(group:, intent:, transport:, policy_recheck: nil, ledger: nil, destinations: nil)
          @group = group
          @intent = intent
          @transport = transport
          @policy_recheck = policy_recheck
          @ledger = ledger || DispatchEvidence
          @destinations = destinations
        end
        # rubocop:enable Metrics/ParameterLists

        # @return [Array<Result>] one entry per attempt. Always an Array: a
        #   parallel group genuinely has one outcome per device, and collapsing
        #   that into a single value is how a partial push failure gets lost.
        def call(now: nil)
          now ||= Time.now.utc
          return [expired_result] if expired?(now)
          return parallel_call if @group.parallel?
          return [attempt(@group.channels.first, channels: @group.channels)] if @group.single_request?

          sequential_call
        end

        private

        def expired?(now)
          !@group.expires_at.nil? && @group.expires_at <= now
        end

        def expired_result
          Result.new(group: @group.name, channel: nil, channels: [], endpoint_ref: nil,
                     outcome: Outcome::EXPIRED, provider_ids: [], reason: "expired")
        end

        # Ordered, and it advances ONLY on a definitive rejection.
        def sequential_call
          results = []
          @group.channels.each do |channel|
            result = attempt(channel, channels: [channel])
            results << result
            break unless Outcome.authorizes_fallback?(result.outcome)
          end
          results
        end

        # Every leg is attempted. A leg's outcome never suppresses another leg
        # and never authorizes a different channel.
        def parallel_call
          return @group.channels.map { |channel| attempt(channel, channels: [channel]) } unless @group.per_device?

          @group.legs.map { |leg| attempt(@group.channels.first, channels: @group.channels, leg:) }
        end

        def attempt(channel, channels:, leg: nil)
          replayed = spent_attempt(channel, leg)
          return replay(replayed, channel, channels, leg) if replayed

          stopped = nil
          classified = nil
          provider_ids = []

          evidence = @ledger.with_claim(intent: @intent, channel_group: @group.name, channel:,
                                        destination_version: leg && leg[:endpoint_ref],
                                        destination: destination_for(channel, leg)) do |_attempt|
            recheck = @policy_recheck&.call(channel:)
            if recheck && !recheck.permitted?
              # A late STOP: the claim exists, the transport is never called,
              # and the attempt settles as a skip rather than an uncertainty.
              stopped = (Array(recheck.reason_codes).first || DEFAULT_STOP_REASON).to_s
              nil
            else
              response = @transport.call(channel:, channels:, group: @group, leg:)
              classified = Outcome.classify(response:)
              provider_ids = Outcome.message_ids(response)
              response
            end
          end

          outcome, reason = resolve(stopped, evidence, classified)
          settle(evidence, outcome, provider_ids, reason)

          Result.new(group: @group.name, channel:, channels:, endpoint_ref: leg && leg[:endpoint_ref],
                     outcome:, provider_ids:, reason:)
        end

        # A Sidekiq retry re-enters `call` with the SAME intent and the same
        # group. Without this lookup the retry would claim a second attempt and
        # call the transport again: one message, two paid sends. Keyed exactly
        # as the claim is (group + channel + destination version), so a
        # per-device fanout still attempts every endpoint once.
        def spent_attempt(channel, leg)
          return nil unless @intent.respond_to?(:attempts)

          @intent.attempts
                 .where(channel_group: @group.name, channel: channel.to_s,
                        destination_version: leg && leg[:endpoint_ref])
                 .where(status: SPENT_ATTEMPT_STATUSES)
                 .order(:id).last
        end

        # No claim, no transport call, no second settle. The prior attempt keeps
        # its own reason; the replayed RESULT says why nothing happened, so a
        # retry is visible rather than looking like a fresh success.
        def replay(attempt_record, channel, channels, leg)
          Result.new(group: @group.name, channel:, channels:,
                     endpoint_ref: leg && leg[:endpoint_ref],
                     outcome: REPLAYED_OUTCOMES.fetch(attempt_record.status, Outcome::UNCERTAIN),
                     provider_ids: replayed_ids(attempt_record),
                     reason: REPLAYED_REASON)
        end

        # A ledger row written before the id ARRAY existed still has only its
        # single column; read whichever the row actually carries.
        def replayed_ids(attempt_record)
          return attempt_record.provider_ids if attempt_record.respond_to?(:provider_ids)

          Array(attempt_record.provider_message_id).compact
        end

        def resolve(stopped, evidence, classified)
          return [Outcome::SKIPPED, stopped] if stopped

          error = evidence.respond_to?(:error) ? evidence.error : nil
          return [classify_error(error), error_reason(error)] if error
          return [Outcome::UNCERTAIN, "missing_provider_id"] if classified.nil? || classified == Outcome::UNCERTAIN

          [classified, nil]
        end

        # A provider that cannot say "never" has not said "try something else".
        def classify_error(error)
          return Outcome.classify(error:) if error.respond_to?(:definitive_rejection?)

          Outcome::UNCERTAIN
        end

        def error_reason(error)
          code = error.error_code if error.respond_to?(:error_code)
          return code if code

          "dispatch_error:#{error.class}"
        end

        # `with_claim` can only settle accepted/uncertain; re-settle with the
        # router's classification so the ledger records what actually happened.
        # A settle failure is deliberately not raised — the work may already
        # have been done, and raising here would invite a duplicate.
        def settle(evidence, outcome, provider_ids, reason)
          attempt_record = evidence.respond_to?(:attempt) ? evidence.attempt : nil
          return if attempt_record.nil?

          @ledger.settle(attempt_record, status: Outcome.attempt_status(outcome),
                                         reason:, provider_message_id: provider_ids.first,
                                         provider_message_ids: provider_ids)
        end

        # Never raises and never blocks a send: an unknown destination is a
        # missing observation, not a reason to refuse a message the policy has
        # already permitted.
        def destination_for(channel, leg)
          return nil if @destinations.nil?

          @destinations.call(channel:, leg:)
        rescue StandardError
          nil
        end
      end
    end
  end
end

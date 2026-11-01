# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # How many people a send would actually reach, how many it would not, and
      # why — computed from {Policy} DECISIONS, never from a count of stored
      # preference keys.
      #
      # That distinction is the whole reason this exists. Six stored
      # city-alert keys once looked like the entire audience; the real
      # compatibility cohort was six, the producer's own enqueue gate admitted
      # 106, and an activated organization default would move the target cohort
      # to 101. A screen that counts rows in a preferences table tells an
      # operator a number that belongs to none of those questions.
      #
      # Three buckets, and every recipient lands in exactly one:
      #
      #   :eligible       at least one channel the policy permits
      #   :suppressed     a CHOICE or a durable STOP refused every channel
      #   :undeliverable  we could not reach them (no address, no template,
      #                   no session, no configured channel) or we could not
      #                   decide at all
      #
      # Keeping "said no" apart from "could not reach" matters: showing a
      # citizen's explicit refusal as a technical defect invites an operator to
      # go and "fix" it.
      #
      # Aggregate-only by construction. Nothing here returns, logs or embeds a
      # recipient identifier, an address, a phone number or a destination
      # digest — only counts, reason codes and fixed descriptors.
      #
      # Deliberately plain Ruby: no Rails, no ActiveSupport. It is loaded by
      # the pure unit suite and must never be able to reach a provider.
      module AudienceEstimate
        # The operator-facing sentence. It is Serbian because an operator reads
        # it, and it names the recheck because the estimate is not a promise:
        # {DispatchGuard} re-asks every one of these questions at send time.
        DISCLAIMER = "Procjena na osnovu trenutnog stanja. Svaka isporuka se ponovo provjerava neposredno prije slanja."

        # A refusal that is somebody's CHOICE or a durable provider STOP. An
        # unlisted reason is deliberately NOT treated as a choice: inventing
        # consent from an unclassified code is the one direction that cannot be
        # undone.
        SUPPRESSION_REASONS = [
          :transport_suppressed,
          :preference_blocked,
          :optional_unsubscribe,
          :provider_opt_out,
          :dispatch_disabled
        ].freeze

        # Channels a provider bills per message. `bell`, `push` and `email` cost
        # nothing here, so counting them as segments would invent a bill.
        BILLABLE_CHANNELS = %w(viber whatsapp sms messenger instagram).freeze

        # A machine-readable descriptor of HOW the number was reached, so a
        # reviewer can check the arithmetic rather than trust it. It is not the
        # operator's copy — {DISCLAIMER} is.
        COST_BASIS = "estimate: one provider-managed chain per eligible recipient, billable channels only"

        # When the decider itself fails, the recipient is counted and named,
        # never dropped. A silently smaller audience reads as "fewer people".
        DECISION_UNAVAILABLE = :decision_unavailable

        # An operator screen must not iterate an unbounded set. Above this the
        # estimate refuses to count rather than making an admin page wait on one
        # policy decision per citizen per channel. It reports the POPULATION and
        # `counted: false`, which the composer renders as "could not count" -
        # never as zeros, because a confident 0 would read as "nobody".
        #
        # The whole base is ~107 citizens today, so this is a ceiling rather
        # than a current limit; it exists so growth does not turn a preview
        # into an outage.
        MAX_COUNTED_RECIPIENTS = 1_000

        module_function

        # @param recipients [Enumerable] opaque; whatever `decide` understands
        # @param channels [Enumerable] passed to `decide` verbatim
        # @param decide [#call] ->(recipient:, channel:) => an object answering
        #   #permitted? and #reason_codes. {Decision} is the real one.
        # @param cost_per_segment [Numeric, nil] nil means "we do not know the
        #   unit price", which produces a degraded cost rather than a number.
        # @return [Hash] counts, a reason histogram and a bounded cost.
        def compute(recipients:, channels:, decide:, cost_per_segment: nil, currency: nil)
          channels = channels.to_a
          buckets = { eligible: 0, suppressed: 0, undeliverable: 0 }
          by_reason = Hash.new(0)
          billable = 0

          recipients.each do |recipient|
            outcome = classify_recipient(recipient:, channels:, decide:)
            buckets[outcome[:bucket]] += 1
            billable += 1 if outcome[:bucket] == :eligible && outcome[:billable]
            outcome[:reasons].each { |reason| by_reason[reason.to_s] += 1 }
          end

          {
            recipients: buckets.values.sum,
            **buckets,
            by_reason: by_reason.sort.to_h,
            cost: cost(segments: billable, cost_per_segment:, currency:),
            counted: true,
            disclaimer: DISCLAIMER
          }
        end

        # What an audience too large to decide one by one looks like. Buckets
        # are deliberately absent rather than zero.
        def uncounted(population:, currency: nil)
          {
            recipients: population,
            eligible: nil, suppressed: nil, undeliverable: nil,
            by_reason: {},
            cost: { segments: nil, amount: nil, currency:, basis: COST_BASIS, degraded: true },
            counted: false,
            disclaimer: DISCLAIMER
          }
        end

        # One recipient, every channel asked. A recipient is eligible if ANY
        # channel is permitted — the send only needs one way in.
        def classify_recipient(recipient:, channels:, decide:)
          permitted = false
          billable = false
          reasons = []

          channels.each do |channel|
            decision = begin
              decide.call(recipient:, channel:)
            rescue StandardError
              nil
            end

            if decision.nil?
              reasons << DECISION_UNAVAILABLE
              next
            end

            if decision.permitted?
              permitted = true
              billable ||= billable_channel?(channel)
            else
              reasons.concat(Array(decision.reason_codes).map(&:to_sym))
            end
          end

          return { bucket: :eligible, billable:, reasons: [] } if permitted

          reasons = reasons.uniq
          { bucket: suppressed?(reasons) ? :suppressed : :undeliverable, billable: false, reasons: }
        end

        # A durable STOP or an explicit "no" is the operative fact about a
        # recipient even when another channel failed for a technical reason:
        # the send must not be retried at them on a different channel.
        def suppressed?(reasons)
          reasons.any? { |reason| SUPPRESSION_REASONS.include?(reason) }
        end

        def billable_channel?(channel)
          BILLABLE_CHANNELS.include?(channel.to_s)
        end

        # ---- the Rails entry point -------------------------------------
        #
        # Same discipline as `Reconciliation.report`: the constants below are
        # resolved when this is CALLED, never when the file is loaded, so the
        # pure suite can still require it without Rails.
        #
        # Read-only by construction. It decides; it never enqueues, claims a
        # token, contacts a provider or writes a preference.
        # rubocop:disable Metrics/ParameterLists
        def for(organization:, message_class:, recipient_ids:, channels: nil, context: {}, mode: nil,
                cost_per_segment: nil, currency: nil)
          entry = MessageClass.fetch(message_class.to_s)
          channels = (channels || entry.channels).map(&:to_s)
          modes = Modes.new(organization:)
          recipients = Decidim::User.where(id: recipient_ids, decidim_organization_id: organization.id).pluck(:id)
          return uncounted(population: recipients.size, currency:).merge(message_class: entry.key, channels:) if
            recipients.size > MAX_COUNTED_RECIPIENTS

          compute(
            recipients:, channels:, cost_per_segment:, currency:,
            decide: lambda { |recipient:, channel:|
              Policy.decide(
                organization:, message_class: entry.key, channel:, context:, mode:, modes:,
                recipient: RecipientContext.account(organization_id: organization.id, account_id: recipient)
              )
            }
          ).merge(message_class: entry.key, channels:)
        end
        # rubocop:enable Metrics/ParameterLists

        def cost(segments:, cost_per_segment:, currency:)
          return { segments:, amount: nil, currency:, basis: COST_BASIS, degraded: true } if cost_per_segment.nil?

          { segments:, amount: segments * cost_per_segment, currency:, basis: COST_BASIS, degraded: false }
        end
      end
    end
  end
end

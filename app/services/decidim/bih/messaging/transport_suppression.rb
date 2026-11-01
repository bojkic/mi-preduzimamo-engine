# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The separate, evidenced way into and out of a transport suppression.
      #
      # This exists because the alternative is worse: if an ordinary settings
      # toggle could clear a provider STOP, a citizen who wrote STOP in a chat
      # would be re-enrolled by the next unrelated save, and the platform would
      # be sending to somebody who told the provider to stop. So suppression is
      # never cleared as a side effect — it is resolved deliberately, with a
      # reference to the evidence that resolved it, and the row stays readable
      # afterwards rather than being deleted.
      #
      # Two properties of real provider feeds are handled here rather than
      # wished away:
      #
      #   * events ARRIVE TWICE. `event_ref` is the provider's own id and a
      #     unique index backs it, so a redelivered webhook is a no-op.
      #   * events arrive LATE. An event that happened BEFORE a reactivation is
      #     still recorded, and is deliberately recorded as already-reactivated:
      #     re-suppressing on it would undo a decision made with newer evidence.
      module TransportSuppression
        class FeedbackNotConfigured < StandardError; end

        module_function

        # rubocop:disable Metrics/ParameterLists
        def suppress!(organization:, provider:, channel:, destination_kind:, destination_digest:,
                      reason:, source:, user: nil, address_version: 1, suppressed_at: nil,
                      occurred_at: nil, event_ref: nil)
          now = suppressed_at || Time.current
          existing = Suppression.active_for(organization:, provider:, channel:, destination_digest:)
          return existing if existing && existing.address_version == address_version

          Suppression.create!(
            organization:, provider:, channel:, destination_kind:, destination_digest:,
            address_version:, reason:, source:, user:, suppressed_at: now,
            occurred_at: occurred_at || now, event_ref:
          )
        end
        # rubocop:enable Metrics/ParameterLists

        # The entry point a provider feed uses. Never raises on a duplicate and
        # never re-suppresses on an event older than the reactivation that
        # resolved it.
        # rubocop:disable Metrics/ParameterLists
        def ingest!(organization:, provider:, channel:, destination:, reason:, source:,
                    event_ref: nil, occurred_at: nil, user: nil)
          digest = SuppressionKey.digest(destination)
          occurred_at ||= Time.current
          recorded = recorded_event(organization:, provider:, event_ref:)
          return recorded if recorded

          latest = Suppression.active_for(organization:, provider:, channel:, destination_digest: digest)
          return upgrade_reason(latest, reason) if latest

          create_event(organization:, provider:, channel:, destination:, digest:, reason:, source:,
                       event_ref:, occurred_at:, user:)
        rescue ActiveRecord::RecordNotUnique
          # Two workers raced on the same provider event. The index decided;
          # read the winner rather than failing a webhook the provider will
          # simply send again.
          recorded_event(organization:, provider:, event_ref:)
        end
        # rubocop:enable Metrics/ParameterLists

        # `evidence` is a reference an operator can follow — a case id, a
        # provider report id, a re-verification record. It is deliberately
        # required: "somebody said it was fine" is not a reactivation.
        def reactivate!(suppression, evidence:)
          raise ArgumentError, "reactivation evidence is required" if evidence.to_s.strip.empty?
          return suppression unless suppression.active?

          suppression.with_lock do
            suppression.update!(reactivated_at: Time.current, reactivation_evidence: evidence.to_s)
          end
          suppression
        end

        # Carry a KNOWN refusal onto a re-issued address. This is an explicit
        # operator action and it is never automatic — a citizen who changes
        # their phone or e-mail gets a NEW destination identity with no
        # suppression at all, because the digest is different and nothing looks
        # up the old one. (Phase 1's own test for this method is titled "does
        # not inherit the old failure", which describes the automatic path this
        # method is NOT part of; recorded in the Phase 3 binding record.)
        def rotate_address!(suppression, destination_digest:)
          suppression.class.create!(
            organization: suppression.organization, provider: suppression.provider,
            channel: suppression.channel, destination_kind: suppression.destination_kind,
            destination_digest:, address_version: suppression.address_version + 1,
            reason: suppression.reason, source: suppression.source, user: suppression.user,
            suppressed_at: Time.current, occurred_at: Time.current
          )
        end

        # ---- internals -------------------------------------------------------

        # A temporary failure that turns out to be a hard bounce must stop
        # being self-expiring. Nothing weakens in this direction: a hard bounce
        # is never downgraded to a temporary one by a later soft event.
        def upgrade_reason(suppression, reason)
          return suppression unless Suppression::SELF_EXPIRING_REASONS.include?(suppression.reason)
          return suppression if Suppression::SELF_EXPIRING_REASONS.include?(reason.to_s)
          return suppression unless Suppression::REASONS.include?(reason.to_s)

          suppression.update!(reason: reason.to_s)
          suppression
        end

        def recorded_event(organization:, provider:, event_ref:)
          return nil if event_ref.blank?

          Suppression.find_by(organization:, provider:, event_ref: event_ref.to_s)
        end

        # rubocop:disable Metrics/ParameterLists
        def create_event(organization:, provider:, channel:, destination:, digest:, reason:, source:,
                         event_ref:, occurred_at:, user:)
          reactivated = latest_reactivation(organization:, provider:, channel:, digest:)
          stale = reactivated && reactivated.reactivated_at > occurred_at

          Suppression.create!(
            organization:, provider:, channel:,
            destination_kind: destination_kind(destination),
            destination_digest: digest,
            address_version: (reactivated&.address_version || 0) + 1,
            reason:, source:, user:, suppressed_at: Time.current, occurred_at:,
            event_ref: event_ref.presence,
            # A late event is RECORDED and does not block: the reactivation was
            # decided with newer evidence, and silently undoing it would mean a
            # citizen who came back is dropped again by a message from before.
            reactivated_at: stale ? reactivated.reactivated_at : nil,
            reactivation_evidence: stale ? "superseded_by_newer_reactivation" : nil
          )
        end
        # rubocop:enable Metrics/ParameterLists

        def latest_reactivation(organization:, provider:, channel:, digest:)
          Suppression.where(organization:, provider:, channel:, destination_digest: digest)
                     .where.not(reactivated_at: nil).order(:reactivated_at).last
        end

        def destination_kind(destination)
          (destination[:kind] || destination["kind"]).to_s
        end
      end
    end
  end
end

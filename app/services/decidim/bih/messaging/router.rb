# frozen_string_literal: true

require "digest"
require_relative "channel_selection"

module Decidim
  module Bih
    module Messaging
      # Evaluates delivery groups without sending, enqueueing or writing.
      # External copies select one suitable route from eligible candidates:
      # a live social session, proven email, or one managed Viber/WhatsApp chain.
      # Inbox and per-device push groups retain their own producer ownership.
      # Expiry is the earliest declared deadline; every excluded candidate
      # retains its reason so a preview can explain why it was not selected.
      module Router
        # A timeout or 5xx is uncertain, so it is never a retry instruction.
        # There is deliberately no other value.
        TIMEOUT_POLICY = :uncertain_no_retry

        # The two channels Infobip's Messages API can fail over between inside
        # ONE request. Keeping them together is what makes a `single` group one
        # billable message rather than two.
        PROVIDER_CHAIN_CHANNELS = %w(viber whatsapp).freeze

        SINGLE_GROUP_MODE = "single"
        PARALLEL_GROUP_MODE = "parallel"
        PER_DEVICE_FANOUT = "per_device"
        PROVIDER_FALLBACK_OWNER = "provider"

        module_function

        # rubocop:disable Metrics/ParameterLists
        def plan(message_class:, recipient:, organization:, context: {}, mode: nil,
                 requested_channels: nil, policy: nil, modes: nil, now: nil)
          entry = resolve_entry(message_class)
          now ||= Time.now.utc
          resolved_context = symbolize(context)
          effective_mode = (mode || Enrollment.mode(organization:, message_class: entry.key, modes:)).to_sym
          decider = policy || Policy
          restriction = caller_restriction(requested_channels, recipient)
          reference = recipient_ref(recipient)

          suppressed = []
          decisions = []
          groups = Array(entry.channel_groups).filter_map do |spec|
            build_group(spec:, entry:, recipient:, organization:, context: resolved_context,
                        mode: effective_mode, restriction:, policy: decider, modes:, now:,
                        suppressed:, decisions:, reference:)
          end

          RoutingPlan.new(
            message_class_key: entry.key, recipient_ref: reference, mode: effective_mode,
            groups:, suppressed:,
            policy_version: decisions.first&.policy_version,
            eligibility_version: decisions.first&.eligibility_version,
            created_at: now
          ).frozen_copy
        end
        # rubocop:enable Metrics/ParameterLists

        # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def build_group(spec:, entry:, recipient:, organization:, context:, mode:, restriction:,
                        policy:, modes:, now:, suppressed:, decisions:, reference:)
          by_channel = evaluate_channels(spec:, entry:, recipient:, organization:, context:, mode:,
                                         restriction:, policy:, modes:, suppressed:, decisions:)
          candidates = by_channel.select { |_channel, decision| decision.permitted? }.keys

          return nil if candidates.empty?

          selected = select_channels(spec, candidates)
          (candidates - selected).each do |channel|
            suppressed << suppression(spec, channel, [:not_selected_single_group], by_channel[channel])
          end

          expires_at = earliest(context[:deadline_at], recipient.deadline_at, ttl_deadline(now, spec, entry),
                                *selected.map { |channel| by_channel[channel].expires_at })
          if expires_at && expires_at <= now
            selected.each { |channel| suppressed << suppression(spec, channel, [:expired], by_channel[channel]) }
            return nil
          end

          DeliveryGroup.new(
            name: spec[:name],
            channels: selected,
            legs: legs_for(spec, context),
            group_mode: spec[:mode],
            fanout: spec[:fanout],
            attempt_strategy: attempt_strategy(spec),
            content_variant: spec[:content_variant],
            content_variant_by_channel: spec[:content_variant_by_channel] || {},
            locale: recipient.locale || context[:locale],
            template: context[:template],
            expires_at:,
            dedup_identity: dedup_identity(entry, spec, context, reference),
            dedup_owner: spec[:deduplication],
            timeout_policy: TIMEOUT_POLICY,
            fallback_owner: spec[:fallback_owner],
            terminates_siblings: false,
            priority: entry.priority,
            preference_adapter: spec[:preference_adapter],
            reason_codes: selected.flat_map { |channel| by_channel[channel].reason_codes }.uniq
          )
        end
        # rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # One Policy decision per candidate channel, in declared order. A channel
        # the caller did not ask for is never decided at all — asking would make
        # a caller restriction look like a preference denial in the artifact.
        # rubocop:disable Metrics/ParameterLists
        def evaluate_channels(spec:, entry:, recipient:, organization:, context:, mode:,
                              restriction:, policy:, modes:, suppressed:, decisions:)
          Array(spec[:channels]).each_with_object({}) do |channel, by_channel|
            # Array#exclude? would need ActiveSupport, and this file is
            # loaded by the pure unit suite. Keep the negation.
            if restriction && !restriction.include?(channel) # rubocop:disable Rails/NegateInclude
              suppressed << suppression(spec, channel, [:caller_restricted], nil)
              next
            end

            decision = policy.decide(organization:, message_class: entry.key, recipient:,
                                     channel:, context:, mode:, modes:)
            decisions << decision
            by_channel[channel] = decision
            suppressed << suppression(spec, channel, decision.reason_codes, decision) unless decision.permitted?
          end
        end
        # rubocop:enable Metrics/ParameterLists

        # The legacy rule, reproduced rather than reinvented
        # (AccountNotifications.preview): one provider-managed phone chain if any
        # phone channel is permitted, otherwise exactly one linked session.
        def select_channels(spec, candidates)
          return candidates unless spec[:mode].to_s == SINGLE_GROUP_MODE

          return ChannelSelection.external(candidates) if spec[:name].to_s == "external_copy"

          chain = candidates & PROVIDER_CHAIN_CHANNELS
          chain.any? ? chain : candidates.first(1)
        end

        def attempt_strategy(spec)
          case spec[:mode].to_s
          when PARALLEL_GROUP_MODE then :parallel
          when SINGLE_GROUP_MODE then :single_request
          else spec[:fallback_owner].to_s == PROVIDER_FALLBACK_OWNER ? :single_request : :sequential
          end
        end

        # Per-device fanout addresses devices, not destinations. The caller
        # supplies opaque endpoint REFERENCES; a real push endpoint never
        # travels through a routing plan.
        def legs_for(spec, context)
          return [] unless spec[:fanout].to_s == PER_DEVICE_FANOUT

          Array(context[:push_endpoint_refs]).map { |ref| { endpoint_ref: ref, outcome: Outcome::QUEUED } }
        end

        def dedup_identity(entry, spec, context, reference)
          [entry.key, spec[:name], context[:deduplication_key] || context[:dedup_key], reference].compact.join(":")
        end

        def suppression(spec, channel, reason_codes, decision)
          { group: spec[:name], channel:, reason_codes: Array(reason_codes).map(&:to_sym),
            policy_version: decision&.policy_version, eligibility_version: decision&.eligibility_version }
        end

        # An explicit empty list means "the caller permits nothing", which is not
        # the same as "the caller expressed no restriction" (nil).
        def caller_restriction(requested_channels, recipient)
          return Array(requested_channels).map(&:to_s) unless requested_channels.nil?

          from_recipient = Array(recipient.requested_channels).map(&:to_s)
          from_recipient.empty? ? nil : from_recipient
        end

        def recipient_ref(recipient)
          return "#{recipient.kind}##{recipient.account_id}" if recipient.account_lookup_allowed?
          return "#{recipient.kind}##{recipient.identity_digest}" if recipient.identity_digest

          # Same formula as DispatchEvidence.safe_reference, so a plan and its
          # ledger row refer to the recipient the same way.
          "#{recipient.kind}##{Digest::SHA256.hexdigest("recipient:#{recipient.kind}:#{recipient.destination}")}"
        end

        def resolve_entry(message_class)
          return message_class if message_class.respond_to?(:channel_groups)

          MessageClass.fetch(message_class.to_s)
        end

        def ttl_deadline(now, spec, entry)
          seconds = spec[:expires_in] || entry.expires_in
          seconds ? now + seconds : nil
        end

        def earliest(*times) = times.compact.min

        def symbolize(context)
          (context || {}).transform_keys(&:to_sym)
        end
      end
    end
  end
end

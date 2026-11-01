# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # One decision API, delegating to purpose-specific contracts.
      #
      # Phase 1 boundary: this is READ-ONLY. Deciding performs no write, no
      # enqueue, no token creation, no provider call and no reconciliation
      # drain, and its result never overrides a legacy caller. A shadow
      # evaluation that raised, hung or disagreed must not be able to deny an
      # otherwise valid authentication request, which is why nothing calls this
      # from a live send path in this phase.
      #
      # Every fact about the world arrives in `context`. The policy does not go
      # and ask a provider whether a template is approved or a session is still
      # open, because asking would be a side effect and because a comparison has
      # to be reproducible from frozen inputs.
      module Policy
        POLICY_VERSION = "mi-topics-2026-09-15"
        ELIGIBILITY_VERSION = "mi-eligibility-2026-09-14"

        # Channels that need a destination before anything can be said about
        # reachability. A bell has no destination; everything else does.
        DESTINATION_FREE_CHANNELS = %w(bell).freeze

        class << self
          # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def decide(organization:, message_class:, recipient:, channel:, context: {},
                     mode: nil, policy_version: nil, eligibility_version: nil, modes: nil)
            entry = MessageClass.fetch(message_class.to_s)
            channel = channel.to_s
            context = channel_scoped((context || {}).transform_keys(&:to_sym), channel)
            mode = (mode || (modes || Modes.new(organization:)).for(entry.key)).to_s
            policy_version ||= POLICY_VERSION
            eligibility_version ||= ELIGIBILITY_VERSION
            build = lambda do |permitted, reasons, origin: "absent", group: nil, expires_at: nil|
              Decision.new(permitted:, reason_codes: reasons, preference_origin: origin,
                           policy_version:, eligibility_version:, expires_at:, mode:,
                           message_class: entry.key, channel:, channel_group: group&.fetch(:name))
            end

            group = entry.group_for(channel)
            return build.call(false, [:unsupported_channel]) unless group
            return build.call(false, [:invalid_recipient_context, *recipient.errors], group:) unless recipient.valid?
            return build.call(false, [:wrong_tenant], group:) unless recipient.organization_id == organization&.id

            user = resolve_user(recipient:, organization:)
            return build.call(false, [:account_unavailable], group:) if recipient.account_lookup_allowed? && user.nil?

            gate = gate_reasons(channel:, recipient:, user:, organization:, context:)
            return build.call(false, gate, group:) if gate.any?

            preference = preference_decision(group:, user:, channel:, context:, mode:)
            expires_at = expiry_for(entry:, group:, context:)
            build.call(preference.allowed?, Array(preference.reason), origin: preference.origin,
                                                                      group:, expires_at:)
          end
          # rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          private

          # Transport capability is per CHANNEL, and the legacy readers already
          # know it: Viber needs a configured business sender, WhatsApp needs
          # that AND an approved template, and a chat channel needs a live
          # linked session and no phone at all. One flat `channel_configured` or
          # `template_valid` flag cannot say that — asserting a missing WhatsApp
          # template would refuse Viber, which is not what the platform does.
          #
          # So a caller that knows the per-channel facts passes them under
          # `channel_context`, and they override the flat ones for that channel
          # only. A context without the key behaves exactly as before.
          def channel_scoped(context, channel)
            overrides = context[:channel_context]
            return context unless overrides.is_a?(Hash)

            per_channel = overrides[channel] || overrides[channel.to_sym]
            return context unless per_channel.is_a?(Hash)

            context.merge(per_channel.transform_keys(&:to_sym))
          end

          def resolve_user(recipient:, organization:)
            return nil unless recipient.account_lookup_allowed?
            return nil if recipient.account_id.nil?

            Decidim::User.where(id: recipient.account_id, decidim_organization_id: organization&.id).first
          end

          # Checks that apply to EVERY purpose, including the ones classified as
          # service. A service classification exempts a topic choice; it does not
          # exempt validity, tenancy, addressability, suppression or a deadline.
          # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def gate_reasons(channel:, recipient:, user:, organization:, context:)
            reasons = []
            reasons << :account_unavailable if user && (user.deleted? || user.blocked?)
            reasons << :invalid_request if context[:request_valid] == false
            reasons << :expired if expired?(context)
            reasons << :destination_unknown if destination_missing?(channel:, recipient:, user:, context:)
            reasons << :channel_unconfigured if context[:channel_configured] == false
            reasons << :template_required if context[:template_valid] == false
            reasons << :connection_required if context[:connection_present] == false
            reasons << :session_expired if social_session_missing?(channel:, context:)
            reasons << :rate_limited if context[:rate_limited] == true
            reasons << :dispatch_disabled if context[:dispatch_disabled] == true
            reasons.concat(suppression_reasons(channel:, organization:, context:))
            reasons.compact
          end
          # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def expired?(context)
            deadline = context[:deadline_at]
            return false if deadline.nil?

            deadline <= Time.current
          end

          # A destination is a fact, not an assumption. Where the caller has not
          # supplied one and we cannot see one on the record, the honest answer
          # is a classified non-send rather than invented reachability.
          def destination_missing?(channel:, recipient:, user:, context:)
            return false if DESTINATION_FREE_CHANNELS.include?(channel)
            # Push addresses devices rather than a destination; its own adapter
            # decides whether a subscription exists.
            return false if channel == "push"
            return false if context[:destination_digest].present? || context[:destination_present] == true
            return false if recipient.destination.present?
            # An account's own e-mail address is already on the record we loaded.
            return false if channel == "email" && user&.email.present?

            true
          end

          # Messenger and Instagram can only be written to inside a live linked
          # session. That is a transport fact, not a topic choice, so it applies
          # whichever preference contract governs the message — and an absent
          # session is a classified non-send rather than an assumption that one
          # is open.
          def social_session_missing?(channel:, context:)
            return false unless %w(messenger instagram).include?(channel)
            return false if context[:connection_present] == false # already reported

            expires_at = context[:session_expires_at]
            expires_at.nil? || expires_at <= Time.current
          end

          # Suppression is a transport rule in every routing mode, including
          # legacy jobs. Topic changes never clear destination refusals.
          def suppression_reasons(channel:, organization:, context:)
            digest = context[:destination_digest]
            return [] if digest.blank?

            suppression = Suppression.blocking_for(
              organization:, provider: context.fetch(:provider, "infobip"), channel:, destination_digest: digest
            )
            suppression ? [:transport_suppressed] : []
          end

          def preference_decision(group:, user:, channel:, context:, mode:)
            adapter = group.fetch(:preference_adapter)
            if channel.to_s != "bell" && context[:notification_topic] && LegacyAdapters.topic_for(adapter)
              allowed = if channel.to_s == "email"
                          ProactiveEmail.allowed?(user, topic: context[:notification_topic])
                        else
                          TopicPreferences.enabled?(user, topic: context[:notification_topic])
                        end
              return LegacyAdapters::Result.new(allowed:, reason: allowed ? nil : :preference_blocked, origin: "topic_preference")
            end
            return LegacyAdapters.evaluate(adapter, user:, channel:, context:) if mode == Modes::LEGACY

            # All modes read the same canonical topic preference. Routing mode
            # changes rollout mechanics, never the citizen's current choice.
            LegacyAdapters.evaluate(adapter, user:, channel:, context:)
          end

          def expiry_for(entry:, group:, context:)
            candidates = [context[:deadline_at]]
            seconds = group[:expires_in] || entry.expires_in
            candidates << (Time.current + seconds) if seconds
            candidates.compact.min
          end
        end
      end
    end
  end
end

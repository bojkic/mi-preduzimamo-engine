# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Produces permitted external candidates for the shared account sender.
      # Callers retain publication, geography, approval and deduplication gates.
      # The account dispatcher rechecks current topic/transport eligibility and
      # chooses one route at the committed claim, immediately before sending.
      # Deferred eligible candidates remain available until that final choice.
      # If enrollment cannot be read, the same canonical checks still run in
      # AccountNotifications' compatibility dispatcher.
      module ExternalCopyRouting
        GROUP = "external_copy"

        # A channel the single-group rule set aside. It is permitted; it simply
        # was not the chain the router would have started with.
        DEFERRED_REASON = :not_selected_single_group

        # Channels addressed by the citizen's stored, verified number. The rest
        # social channels use linked sessions; email uses its confirmed address.
        PHONE_CHANNELS = %w(viber whatsapp).freeze
        SOCIAL_CHANNELS = %w(messenger instagram).freeze

        Decision = Struct.new(:routed, :channels, :plan, keyword_init: true) do
          def routed? = routed == true
        end

        # "Run your legacy body." Not the same as a routed decision that found
        # no channel — that one is `routed: true, channels: []`.
        LEGACY = Decision.new(routed: false, channels: nil, plan: nil).freeze

        module_function

        # @param requested_channels [Array<String>] exactly what the legacy
        #   caller would have passed to `AccountNotifications`
        # @param modes [Messaging::Modes, nil] one snapshot per job; a caller
        #   iterating a chunk of recipients must build it once and pass it
        # @return [Decision]
        # rubocop:disable Metrics/ParameterLists
        def decide(user:, organization:, message_class:, requested_channels:, deadline_at: nil,
                   dedup_key: nil, modes: nil)
          requested = Array(requested_channels).map(&:to_s)
          modes ||= Enrollment.modes_for(organization)
          return LEGACY unless Enrollment.routes?(organization:, message_class:, modes:)

          plan = Router.plan(
            message_class:, organization:, modes:,
            mode: Enrollment.mode(organization:, message_class:, modes:),
            recipient: recipient_for(user:, organization:, requested:, deadline_at:),
            requested_channels: requested,
            context: context_for(user:, organization:, requested:, deadline_at:, dedup_key:)
          )
          Decision.new(routed: true, channels: candidates(plan), plan:)
        rescue StandardError => e
          report(e, message_class)
          LEGACY
        end
        # rubocop:enable Metrics/ParameterLists

        # The permitted candidates for the external copy: the group the router
        # selected, plus every channel it deferred under the single-group rule.
        def candidates(plan)
          group = plan.group(GROUP)
          deferred = Array(plan.suppressed).filter_map do |entry|
            entry[:channel] if entry[:group] == GROUP && Array(entry[:reason_codes]).include?(DEFERRED_REASON)
          end
          (Array(group&.channels) + deferred).uniq
        end

        def recipient_for(user:, organization:, requested:, deadline_at:)
          RecipientContext.account(
            organization_id: organization.id, account_id: user.id,
            locale: user.try(:locale).presence || organization.default_locale,
            requested_channels: requested, deadline_at:
          )
        end

        def context_for(user:, organization:, requested:, deadline_at:, dedup_key:)
          connections = social_connections(user:, organization:, channels: requested)
          {
            deadline_at:,
            dedup_key:,
            channel_context: {
              "email" => { destination_present: user.email.present?, channel_configured: EmailConfirmation.confirmed?(user),
                           provider: "smtp", destination_digest: user.email.present? ? SuppressionKey.digest(kind: "email", value: user.email) : nil }
            },
            destination_present: destination_present?(user:, organization:, channels: requested,
                                                      connections:),
            # Messenger and Instagram can only be written to inside a live
            # linked session, and `Policy` treats an ABSENT session as a denial.
            # Without this the router would be STRICTER than
            # `AccountNotifications.preview` and could drop a delivery legacy
            # would have made. One value for the group, taking the longest-lived
            # session: `preview` still refuses each channel individually at
            # claim time, so erring wide here can only ever record an extra
            # channel, never send on one.
            session_expires_at: connections.filter_map(&:session_expires_at).max
          }
        end

        def social_connections(user:, organization:, channels:)
          (channels & SOCIAL_CHANNELS).filter_map do |channel|
            ChannelConnections.for_user(user:, organization:, channel:)
          end
        end

        # The same destination facts `AccountNotifications.preview` reads, so a
        # plan never claims reachability the sender does not have. One answer
        # for the whole group, because `Policy.decide` takes one context per
        # channel and the per-channel transport check is `preview`'s at claim
        # time — this only has to stop a plan being built for a citizen the
        # sender has no way to address at all.
        def destination_present?(user:, organization:, channels:, connections:)
          phone = channels.any? { |channel| PHONE_CHANNELS.include?(channel) }
          return true if phone && VerifiedPhone.delivery_phone_for(user:, organization:).present?

          connections.any?
        end

        def report(error, message_class)
          return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

          Rails.logger.warn(
            "[Messaging::ExternalCopyRouting] #{message_class} fell back to the legacy body: #{error.class}"
          )
        end
      end
    end
  end
end

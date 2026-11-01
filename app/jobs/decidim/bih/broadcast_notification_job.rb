# frozen_string_literal: true

module Decidim
  module Bih
    # Resolves immutable broadcast content by ID, then creates one encrypted
    # account-scoped delivery per recipient. Retries cannot duplicate that intent.
    class BroadcastNotificationJob < ChunkedBellJob
      MESSAGE_CLASS = "komsiluk.area_broadcast"

      # All notification params are passed as a single options hash to stay within
      # the RuboCop Metrics/ParameterLists limit (max 5 named params).
      #
      # Expected keys:
      #   organization_id [Integer]
      #   user_ids        [Array<Integer>]  chunk of ≤50 recipient ids
      #   message         [String]          operator-composed message text
      #   area_name       [String]          translated name of the area
      #   area_id         [Integer]         local_area id (for extra payload)
      #   channels        [Array<String>]   e.g. ["bell"] or ["bell", "viber"]
      def perform(opts = {})
        opts = opts.with_indifferent_access
        if opts[:broadcast_id]
          broadcast = Broadcast.find_by(id: opts[:broadcast_id], decidim_organization_id: opts[:organization_id])
          return unless broadcast

          opts = opts.merge(message: broadcast.message, area_name: broadcast.area.translated_name,
                            area_id: broadcast.local_area_id, channels: broadcast.channels.to_s.split(","))
        end
        organization_id = opts[:organization_id]
        user_ids = Array(opts[:user_ids])
        message = opts[:message].to_s
        area_name = opts[:area_name].to_s
        area_id = opts[:area_id]
        channels = Array(opts[:channels]).map(&:to_s)

        organization = Decidim::Organization.find_by(id: organization_id)
        return unless organization

        external_channels = channels.intersect?(AccountNotifications::CHANNELS) ? Messaging::BroadcastChannels.for(organization) : []
        # One enrollment snapshot per JOB, not per recipient: `Modes` reads the
        # organization's settings namespace once per instance, and a chunk of
        # fifty recipients must not become fifty settings reads. A job instance
        # serves exactly one `perform`, so this is per-chunk state.
        @modes = Messaging::Modes.new(organization:)

        each_eligible_user(organization, user_ids) do |user|
          selected = WebPush.available_for?(user, topic: :neighborhood_info) || external_channels.empty? ? "push" : "external"
          deliver_bell(user, message:, area_name:, area_id:, organization_id:, proactive_channel: selected)
          next unless selected == "external"

          deliver_external(user, message:, organization:, channels: external_channels,
                                 broadcast_id: opts[:broadcast_id])
        end
      end

      private

      def deliver_bell(user, message:, area_name:, area_id:, organization_id:, proactive_channel: "push") # rubocop:disable Metrics/ParameterLists
        Decidim::EventsManager.publish(
          event: "decidim.events.bih.local_broadcast",
          event_class: Decidim::Bih::LocalBroadcastEvent,
          resource: user,
          affected_users: [user],
          force_send: true,
          extra: {
            "message" => message,
            "area_name" => area_name,
            "area_id" => area_id,
            "organization_id" => organization_id,
            "proactive_channel" => proactive_channel
          }
        )
      rescue StandardError => e
        Rails.logger.error(
          "[BroadcastNotificationJob] bell delivery failed for user #{user.id}: " \
          "#{e.class}: #{e.message}"
        )
        nil
      end

      # The inbox is always created. A frozen per-event choice ensures a push
      # and an external copy do not both nudge the same recipient.
      def deliver_external(user, message:, organization:, channels:, broadcast_id:)
        # Old queue entries lack a stable broadcast identity and cannot be safely
        # deduplicated. Their bell remains supported; paid sends fail closed.
        return if broadcast_id.blank?

        dedup_key = "broadcast:#{broadcast_id}"
        AccountNotifications.enqueue!(user:, organization:, topic: :neighborhood_info, text: message,
                                      channels: routed_channels(user:, organization:, channels:, dedup_key:),
                                      deduplication_key: dedup_key, message_class: MESSAGE_CLASS)
      rescue StandardError => e
        Rails.logger.error("[BroadcastNotificationJob] account delivery #{user.id}: #{e.class}")
      end

      # Provider-ready candidates are narrowed by current topic/reachability.
      # The dispatcher chooses and rechecks the route again inside its claim.
      def routed_channels(user:, organization:, channels:, dedup_key:)
        decision = Messaging::ExternalCopyRouting.decide(
          user:, organization:, message_class: MESSAGE_CLASS,
          requested_channels: channels, dedup_key:, modes: @modes
        )
        decision.routed? ? decision.channels : channels
      end
    end
  end
end

# frozen_string_literal: true

require_relative "messaging/broadcast_channels"

module Decidim
  module Bih
    # Service that fans out an operator-authored message to all citizens in a
    # Komšiluk or Mjesna zajednica (MZ).
    #
    # Usage:
    #   result = KomsilukBroadcast.call(
    #     organization: org,
    #     area:         local_area,   # LocalArea of kind "mz" or "komsiluk"
    #     message:      "Sutra čišćenje Trga.",
    #     channels:     ["bell"],     # or ["bell", "viber"]
    #     sent_by:      admin_user
    #   )
    #   result[:broadcast]          # => Decidim::Bih::Broadcast (audit record)
    #   result[:recipients_count]   # => Integer
    #
    # Privacy contract (enforced here):
    #   - Recipient list is never logged or returned to the caller.
    #   - Notification copy is generic — it does NOT name other recipients.
    #   - Area name is passed to the bell via extra; the job never exposes the
    #     list of user_ids to the notification payload itself.
    #
    # Idempotency: a Broadcast audit record is created BEFORE jobs are enqueued.
    # If this method is called again with identical params it will create a NEW
    # broadcast and re-send (the admin made a second deliberate submission).
    # Double-click protection is the controller's responsibility.
    class KomsilukBroadcast
      # Recipients per enqueued job; defined once on the shared job base.
      CHUNK_SIZE = ChunkedBellJob::CHUNK_SIZE

      # @param organization [Decidim::Organization]
      # @param area         [Decidim::Bih::LocalArea]  kind mz or komsiluk
      # @param message      [String]
      # @param channels     [Array<String>]  subset of %w[bell viber]
      # @param sent_by      [Decidim::User]  the admin who initiated the send
      # @return [Hash] { broadcast:, recipients_count: }
      def self.call(organization:, area:, message:, channels:, sent_by:)
        new(organization:, area:, message:, channels:, sent_by:).call
      end

      # Preview the audience without creating an audit record or enqueueing any
      # notifications. The caller receives only an aggregate count.
      def self.preview(organization:, area:, message:, channels:, sent_by:)
        new(organization:, area:, message:, channels:, sent_by:).preview
      end

      def initialize(organization:, area:, message:, channels:, sent_by:)
        @organization = organization
        @area = area
        # Defense-in-depth: hard-cap the message so a too-long payload can never
        # reach Viber dispatch even if the model/controller guard is bypassed.
        @message = message.to_s.strip[0, Broadcast::MAX_MESSAGE_LENGTH].to_s
        @channels = Array(channels).map(&:to_s).uniq
        @sent_by = sent_by
      end

      def call
        user_ids = resolve_recipient_ids
        count = user_ids.size

        broadcast = create_broadcast!(count)
        enqueue_jobs(user_ids, broadcast) if count.positive?

        { broadcast:, recipients_count: count }
      end

      def preview
        ids = resolve_recipient_ids
        result = { recipients_count: ids.size }
        external = channels.intersect?(AccountNotifications::CHANNELS) ? Messaging::BroadcastChannels.for(organization) : []
        return result if external.empty?

        counts = external.index_with { 0 }
        skipped = 0
        Decidim::User.where(organization:, id: ids).find_each do |user|
          decision = AccountNotifications.preview(user:, organization:, topic: :neighborhood_info, text: message, channels: external)
          decision[:channels].each { |channel| counts[channel] += 1 }
          skipped += 1 unless decision[:eligible]
        end
        result.merge(delivery_counts: counts, skipped_count: skipped)
      end

      private

      attr_reader :organization, :area, :message, :channels, :sent_by

      # Resolve the unique Decidim user ids for eligible recipients.
      #
      # Delegates audience + active-user resolution to the shared
      # Komsiluk::MembershipResolver. A broadcast targets the WHOLE audience: it
      # does NOT exclude the operator and does NOT honour the per-user board
      # opt-out (an operator broadcast is a deliberate org-level message, unlike
      # the urgent-post bell).
      def resolve_recipient_ids
        resolver = case area.kind
                   when "komsiluk"
                     Komsiluk::MembershipResolver.for_komsiluk(organization:, komsiluk_id: area.id)
                   when "mz"
                     Komsiluk::MembershipResolver.for_mz(organization:, mz_area: area)
                   end
        return [] unless resolver

        resolver.recipient_ids(exclude_user_id: nil, honor_opt_out: false)
      end

      def create_broadcast!(recipients_count)
        Broadcast.create!(
          organization:,
          area:,
          sent_by:,
          message:,
          channels: channels.join(","),
          recipients_count:
        )
      end

      def enqueue_jobs(user_ids, broadcast)
        user_ids.each_slice(CHUNK_SIZE) do |chunk|
          BroadcastNotificationJob.perform_later(
            organization_id: organization.id,
            user_ids: chunk,
            broadcast_id: broadcast.id
          )
        end
      end
    end
  end
end

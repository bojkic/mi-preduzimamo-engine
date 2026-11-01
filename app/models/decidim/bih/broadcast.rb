# frozen_string_literal: true

module Decidim
  module Bih
    # Immutable audit record for each operator-initiated Komšiluk broadcast.
    # Created by KomsilukBroadcast.call before fan-out begins. Never updated
    # after creation — the recipients_count is set at create time and is not
    # adjusted if individual deliveries fail.
    #
    # `channels` stores a comma-separated string ("bell" or "bell,viber") so
    # that it is human-readable in the DB without needing a jsonb cast.
    class Broadcast < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_broadcasts"

      RECENT_LIMIT = 50

      # Server-side cap mirroring the "Maximum 500 characters" UI promise.
      MAX_MESSAGE_LENGTH = 500

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :area,
                 class_name: "Decidim::Bih::LocalArea",
                 foreign_key: "local_area_id"

      # Optional: admin who sent it. Nullable via :nullify on the FK.
      belongs_to :sent_by,
                 class_name: "Decidim::User",
                 optional: true

      validates :message, presence: true
      validates :message, length: { maximum: MAX_MESSAGE_LENGTH }
      validates :channels, presence: true
      validates :recipients_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

      scope :recent, -> { order(created_at: :desc) }

      # Convenience reader: channels as an Array.
      def channels_list
        channels.to_s.split(",").map(&:strip).compact_blank
      end

      def viber?
        channels_list.include?("viber")
      end
    end
  end
end

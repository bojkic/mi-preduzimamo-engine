# frozen_string_literal: true

module Decidim
  module Bih
    # Receipt evidence is independent of queue/provider acceptance. A browser
    # display acknowledgment proves display API completion, never human reading.
    class PlatformDelivery < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_platform_deliveries"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
      belongs_to :komsiluk_post, class_name: "Decidim::Bih::KomsilukPost", optional: true
      ACK_WAIT = 15.minutes

      def self.for!(user:, identity:, expires_at:)
        create_or_find_by!(organization: user.organization, user:, identity:) do |row|
          row.expires_at = expires_at
          row.deadline_at = [Time.current + ACK_WAIT, expires_at].min
        end
      end

      def acknowledge!(kind)
        with_lock do
          attributes = {}
          attributes.merge!(acknowledged_at: Time.current, acknowledgment_kind: kind) unless acknowledged_at
          attributes[:browser_displayed_at] = Time.current if kind == "browser_display" && browser_displayed_at.nil?
          attributes[:inbox_read_at] = Time.current if kind == "inbox_read" && inbox_read_at.nil?
          update!(attributes) if attributes.any?
        end
      end

      def receipt_token
        signed_id(purpose: :platform_display_receipt, expires_in: [expires_at - Time.current, 1].max)
      end

      def fallback_due?
        !cancelled_at && !acknowledged_at && expires_at > Time.current && deadline_at <= Time.current
      end
    end
  end
end

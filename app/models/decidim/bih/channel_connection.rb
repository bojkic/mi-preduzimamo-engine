# frozen_string_literal: true

module Decidim
  module Bih
    # A scoped messaging address, never an authentication grant or consent.
    class ChannelConnection < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_channel_connections"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
      scope :active, -> { where(revoked_at: nil) }
      validates :channel, inclusion: { in: %w(whatsapp messenger instagram) }
      validates :business_sender, :recipient_digest, :recipient_ciphertext, :verified_at, presence: true
      validate :account_belongs_to_organization
      self.filter_attributes += [:recipient_ciphertext, :recipient_digest]

      def account_belongs_to_organization
        errors.add(:user, :invalid) unless user && user.decidim_organization_id == decidim_organization_id
      end

      def recipient_id
        return if revoked_at.present?

        ChannelConnections.decrypt(recipient_ciphertext)
      end
      alias recipient recipient_id

      def session_expires_at
        last_inbound_at && (last_inbound_at + 23.hours)
      end
    end
  end
end

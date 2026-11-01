# frozen_string_literal: true

module Decidim
  module Bih
    # One logical delivery, never an instruction to retry a possibly accepted send.
    class AccountNotification < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_account_notifications"
      self.filter_attributes += [:payload_ciphertext]
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
      validates :topic, inclusion: { in: NotificationPreferences::TOPICS }
      validates :status, inclusion: { in: %w(pending sending accepted rejected failed unknown skipped delivered) }
      validates :payload_ciphertext, :deduplication_digest, :expires_at, presence: true

      def payload
        Infobip::EncryptedJobEnvelope.open(payload_ciphertext, purpose: "account-notification", salt: "bih-account-notifications-v1")
      end

      def payload=(value)
        self.payload_ciphertext = Infobip::EncryptedJobEnvelope.seal(value, purpose: "account-notification", salt: "bih-account-notifications-v1")
      end
    end
  end
end

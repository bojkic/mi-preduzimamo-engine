# frozen_string_literal: true

module Decidim
  module Bih
    class ReportServiceSender < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_service_senders"
      include MailboxEncryptedFields
      mailbox_encrypts :email
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      scope :active, -> { where(active: true) }
      validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }
      validates :label, presence: true
      before_validation { self.email_digest = ReportMailbox::ReplyAddress.digest_address(email) }
      def masked_email = "***@#{email.to_s.split('@').last}"
    end
  end
end

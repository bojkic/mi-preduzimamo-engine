# frozen_string_literal: true

module Decidim
  module Bih
    class ReportReplyCapability < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_reply_capabilities"
      include MailboxEncryptedFields
      mailbox_encrypts :token
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :report, class_name: "Decidim::Bih::Report", foreign_key: :decidim_bih_report_id
      belongs_to :question_message, class_name: "Decidim::Bih::ReportMessage", optional: true
      scope :active, -> { where(revoked_at: nil) }
      validates :audience, inclusion: { in: %w(service citizen) }
      validates :token_digest, :token_ciphertext, :correspondent_digests, presence: true
      validate do
        errors.add(:report, :invalid) if report && report.organization != organization
        errors.add(:question_message, :invalid) if question_message && (question_message.report != report || audience != "citizen" || question_message.kind != "question")
      end
      def correspondent?(address) = correspondent_digests.include?(ReportMailbox::ReplyAddress.digest_address(address))
      def revoke! = update!(revoked_at: Time.current)
    end
  end
end

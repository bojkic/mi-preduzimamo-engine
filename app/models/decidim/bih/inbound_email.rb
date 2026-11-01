# frozen_string_literal: true

module Decidim
  module Bih
    class InboundEmail < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_inbound_emails"
      include PrivateReportAttachments
      include MailboxEncryptedFields
      mailbox_encrypts :subject, :body_text, :raw
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :dismissed_by, class_name: "Decidim::User", optional: true
      has_many :inbound_email_links, class_name: "Decidim::Bih::InboundEmailLink", dependent: :destroy
      has_many :reports, through: :inbound_email_links
      has_many_attached :attachments, service: ->(_record) { ReportPrivateStorage.service_name }
      CLASSIFICATIONS = %w(candidate auto_reply bounce system_notice outbound_copy staff_sent draft).freeze
      STATES = %w(stored processing processed review history ignored failed).freeze
      validates :state, inclusion: { in: STATES }
      validates :classification, inclusion: { in: CLASSIFICATIONS }, allow_nil: true
      validates :account, :folder, :gm_msgid, :internal_date, presence: true
      before_update do
        if history_only_in_database && !history_only
          errors.add(:history_only, "Historical mail cannot trigger actions")
          throw :abort
        end
      end
      def links = inbound_email_links

      def sender_address = Array(Mail.read_from_string(raw.to_s).from).first

      def new_part = raw.present? ? ReportMailbox::ReplyText.new_part(Mail.read_from_string(raw)) : body_text.to_s
    end
  end
end

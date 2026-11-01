# frozen_string_literal: true

module Decidim
  module Bih
    class InboundEmailLink < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_inbound_email_links"
      belongs_to :inbound_email, class_name: "Decidim::Bih::InboundEmail"
      belongs_to :report, class_name: "Decidim::Bih::Report", foreign_key: :decidim_bih_report_id
      belongs_to :capability, class_name: "Decidim::Bih::ReportReplyCapability", optional: true
      belongs_to :created_by, class_name: "Decidim::User", optional: true
      alias_attribute :report_id, :decidim_bih_report_id
      validates :matching_method, inclusion: { in: %w(capability in_reply_to gmail_thread reference manual) }
      validates :assurance, inclusion: { in: %w(capability authenticated_thread citizen association) }
      validate { errors.add(:report, :invalid) if report && inbound_email && report.organization != inbound_email.organization }
    end
  end
end

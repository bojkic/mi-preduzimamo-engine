# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module Associator
        def self.delivered_addresses(mail)
          Array(mail["Delivered-To"]).flat_map { |field| Mail::AddressList.new(field.value.to_s).addresses.map(&:address) }
        rescue Mail::Field::ParseError
          []
        end

        def self.call(mail, organization:, gm_thrid: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          links = {}
          addresses = Array(mail.to) + Array(mail.cc) + delivered_addresses(mail)
          addresses.each do |address|
            capability = ReplyAddress.resolve(address, organization:)
            links[capability.report.id] = { report: capability.report, matching_method: "capability", capability: } if capability
          end
          ids = Array(mail.references) + Array(mail.in_reply_to)
          ReportDispatch.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id }, message_id: ids).find_each do |dispatch|
            links[dispatch.report.id] ||= { report: dispatch.report, matching_method: "in_reply_to", capability: nil }
          end
          # Only the subject and the new text: our own quoted e-mail often names
          # other cases and must not link the reply to them.
          references = Reference.scan([mail.subject, ReplyText.new_part(mail)].join("\n"))
          Report.where(organization:, reference: references).each { |report| links[report.id] ||= { report:, matching_method: "reference", capability: nil } }
          # Gmail groups similar subjects into one thread across different
          # cases; use the thread only when nothing more precise matched.
          if gm_thrid.present? && links.empty?
            InboundEmail.where(organization:, gm_thrid:, classification: "outbound_copy").includes(inbound_email_links: :report).each do |email|
              email.inbound_email_links.each { |link| links[link.report.id] ||= { report: link.report, matching_method: "gmail_thread", capability: nil } }
            end
          end
          if mail.message_id.present?
            ReportDispatch.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id }, message_id: mail.message_id).each do |dispatch|
              links[dispatch.report.id] ||= { report: dispatch.report, matching_method: "in_reply_to", capability: nil }
            end
          end
          links.values
        end
      end
    end
  end
end

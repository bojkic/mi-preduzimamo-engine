# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module Assurance
        def self.call(mail, link:, organization:)
          return "association" unless Array(mail.from).one?
          sender = mail.from.first.to_s.downcase
          capability = link[:capability]
          approved = ReportServiceSender.active.exists?(organization:, email_digest: ReplyAddress.digest_address(sender))
          if capability && !capability.revoked_at && capability.correspondent?(sender)
            return "capability" if capability.audience == "service" && approved
            author = link[:report].author
            return "citizen" if capability.audience == "citizen" && author&.confirmed? && author.email.to_s.casecmp?(sender)
          end
          return "association" unless approved && link[:matching_method] == "in_reply_to"
          associated = Associator.call(mail, organization:)
          return "association" unless associated.map { |item| item[:report].id }.uniq == [link[:report].id]
          ids = Array(mail.references) + Array(mail.in_reply_to)
          same_recipient = link[:report].dispatches.where(message_id: ids, state: "accepted").any? do |dispatch|
            Array(dispatch.snapshot["to"]).any? { |to| to.casecmp?(sender) }
          end
          return "association" unless same_recipient
          authentication = GoogleAuthentication.parse(mail)
          domain = sender.split("@", 2).last
          aligned = authentication["dkim"] == "pass" && Array(authentication["dkim_domains"]).include?(domain)
          aligned ||= authentication["dmarc"] == "pass" && authentication["from_domain"] == domain
          aligned ? "authenticated_thread" : "association"
        end
      end
    end
  end
end

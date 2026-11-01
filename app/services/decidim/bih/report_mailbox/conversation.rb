# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module Conversation
        def self.message_ids(report:, correspondents:)
          expected = Array(correspondents).map { |address| address.to_s.strip.downcase }.sort
          entries = report.dispatches.where(state: "accepted").filter_map do |dispatch|
            next unless Array(dispatch.snapshot["to"]).map(&:downcase).sort == expected
            [dispatch.accepted_at, dispatch.message_id]
          end
          if defined?(InboundEmail) && InboundEmail.table_exists?
            InboundEmailLink.where(report:, assurance: %w(capability authenticated_thread)).includes(:inbound_email).each do |link|
              mail = link.inbound_email
              next unless expected.map { |address| ReplyAddress.digest_address(address) }.include?(mail.from_digest)
              entries << [mail.internal_date, mail.message_id] if mail.message_id.present?
            end
          end
          entries.sort_by { |at, id| [at, id] }.map(&:last).uniq
        end
      end
    end
  end
end

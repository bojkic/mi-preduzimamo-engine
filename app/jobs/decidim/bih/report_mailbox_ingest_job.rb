# frozen_string_literal: true

module Decidim
  module Bih
    class ReportMailboxIngestJob < ApplicationJob
      queue_as :default
      def perform(organization_id)
        target = ReportMailbox::Target.resolve!
        raise ReportMailbox::Config::Invalid, "Mailbox organization mismatch" unless target.organization.id == organization_id.to_i
        adapter = ReportMailbox::ImapAdapter.new(config: target.config)
        ReportMailbox::Ingest.new(organization: target.organization, adapter:).call
      end
    end
  end
end

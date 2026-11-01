# frozen_string_literal: true

module Decidim
  module Bih
    class ReportMailboxProcessJob < ApplicationJob
      queue_as :default
      def perform(inbound_email_id)
        email = InboundEmail.find_by(id: inbound_email_id)
        ReportMailbox::ProcessMessage.new(email).call if email
      end
    end
  end
end

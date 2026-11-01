# frozen_string_literal: true

module Decidim
  module Bih
    class MailboxCursor < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_mailbox_cursors"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      def activate!
        with_lock do
          raise ArgumentError, "Mailbox already activated" if activation_at
          update!(activation_at: Time.current)
        end
      end
    end
  end
end

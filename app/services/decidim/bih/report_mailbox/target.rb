# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      # One configured Gmail account has exactly one tenant owner. Neither a
      # shared global poll nor a guessed current tenant may copy private mail.
      module Target
        Selection = Struct.new(:organization, :account, :config, keyword_init: true)
        module_function

        def activate!(organization_id:)
          target = resolve!
          raise Config::Invalid, "Activation organization mismatch" unless organization_id.to_s == target.organization.id.to_s
          adapter = ImapAdapter.new(config: target.config)
          begin
            opened = adapter.open
            cursor = MailboxCursor.find_or_create_by!(organization: target.organization, account: target.account) do |record|
              record.folder = opened.fetch(:folder)
            end
            cursor.activate!
            cursor
          ensure
            adapter.close
          end
        end

        def resolve!
          config = Config.load or raise Config::Invalid, "Mailbox configuration unavailable"
          configured_id = ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"].to_s
          organization = if configured_id.present?
                           raise Config::Invalid, "Invalid mailbox organization" unless configured_id.match?(/\A[1-9]\d*\z/)
                           Decidim::Organization.find_by(id: configured_id)
                         else
                           candidates = Decidim::Organization.limit(2).to_a
                           raise Config::Invalid, "Explicit mailbox organization required for multiple tenants" unless candidates.one?
                           candidates.first
                         end
          raise Config::Invalid, "Mailbox organization unavailable" unless organization
          account = config.username.to_s.strip.downcase
          expected = Decidim::Bih.report_reply_mailbox.to_s.strip.downcase
          raise Config::Invalid, "Mailbox account identity mismatch" unless account.present? && account == expected

          if MailboxCursor.where("LOWER(account) = ?", account).where.not(decidim_organization_id: organization.id).exists?
            raise Config::Invalid, "Mailbox already owned by another organization"
          end

          Selection.new(organization:, account:, config:)
        end
      end
    end
  end
end

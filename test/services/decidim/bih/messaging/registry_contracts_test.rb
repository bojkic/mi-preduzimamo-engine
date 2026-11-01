# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/recipient_context"
require_relative "../../../../../app/services/decidim/bih/messaging/message_class"

module Decidim
  module Bih
    module Messaging
      # Cross-checks between the two Task 1.1 contracts. They are loadable
      # separately on purpose, so the lists they each declare need a test that
      # loads both and refuses to let them drift.
      class RegistryContractsTest < Minitest::Test
        def test_recipient_kinds_agree
          assert_equal RecipientContext::KINDS.sort, MessageClass::RECIPIENT_KINDS.sort
        end

        def test_channel_vocabularies_agree
          assert_equal RecipientContext::CHANNELS.sort, MessageClass::CHANNELS.sort
        end

        def test_every_registry_entry_can_build_a_valid_recipient_context
          MessageClass.all.each_value do |entry|
            entry.recipient_kinds.each do |kind|
              context = build_context(kind)

              assert context.valid?, "#{entry.key}/#{kind}: #{context.errors.inspect}"
            end
          end
        end

        def test_requested_channels_of_an_entry_are_acceptable_recipient_channels
          MessageClass.all.each_value do |entry|
            context = RecipientContext.account(organization_id: 1, account_id: 1, requested_channels: entry.channels)

            assert context.valid?, "#{entry.key}: #{context.errors.inspect}"
          end
        end

        def test_an_anonymous_or_provider_recipient_is_never_account_resolvable
          %w(anonymous_report_contact provider_inbound_identity external_institution operator_mailbox).each do |kind|
            refute build_context(kind).account_lookup_allowed?, kind
          end
        end

        private

        def build_context(kind)
          case kind
          when "account" then RecipientContext.account(organization_id: 1, account_id: 1)
          when "staff" then RecipientContext.staff(organization_id: 1, account_id: 1, audience_role: "reports_read")
          when "pending_authentication" then RecipientContext.pending_authentication(organization_id: 1, destination: "+38765000000")
          when "anonymous_report_contact"
            RecipientContext.anonymous_report_contact(organization_id: 1, destination: "r@example.org", destination_channel: "email")
          when "external_institution" then RecipientContext.external_institution(organization_id: 1, destination: "city@example.org")
          when "operator_mailbox" then RecipientContext.operator_mailbox(organization_id: 1, destination: "ops@example.org")
          when "provider_inbound_identity"
            RecipientContext.provider_inbound_identity(organization_id: 1, channel: "whatsapp", identity_digest: "c" * 64)
          else raise ArgumentError, "unhandled kind #{kind}"
          end
        end
      end
    end
  end
end

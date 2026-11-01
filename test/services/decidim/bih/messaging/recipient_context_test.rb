# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/recipient_context"

module Decidim
  module Bih
    module Messaging
      # A recipient is not always an account, and an account is never inferred
      # from a phone number or an opaque provider identity. These tests fix that
      # boundary before any policy or router can blur it.
      class RecipientContextTest < Minitest::Test
        def test_account_recipient_requires_a_tenant_and_an_account
          context = RecipientContext.account(organization_id: 1, account_id: 7)

          assert context.valid?, context.errors.inspect
          assert_equal "account", context.kind
          assert context.account_lookup_allowed?

          refute RecipientContext.account(organization_id: 1, account_id: nil).valid?
          refute RecipientContext.account(organization_id: nil, account_id: 7).valid?
        end

        def test_pending_authentication_uses_the_validated_requested_destination
          context = RecipientContext.pending_authentication(
            organization_id: 1, destination: "+387650000000", destination_channel: "phone"
          )

          assert context.valid?, context.errors.inspect
          refute context.requires_verified_destination?,
                 "requiring prior verification here would make registration impossible"
          assert_equal "+387650000000", context.destination
        end

        def test_pending_authentication_without_a_destination_is_invalid
          context = RecipientContext.pending_authentication(organization_id: 1, destination: nil, destination_channel: "phone")

          refute context.valid?
          assert_includes context.errors, :destination_required
        end

        def test_anonymous_report_contact_never_carries_an_account
          context = RecipientContext.anonymous_report_contact(
            organization_id: 1, destination: "reporter@example.org", destination_channel: "email",
            resource_type: "Decidim::Bih::Report", resource_id: 42
          )

          assert context.valid?, context.errors.inspect
          refute context.account_lookup_allowed?
          assert_nil context.account_id

          matched = RecipientContext.new(
            kind: "anonymous_report_contact", organization_id: 1, account_id: 9,
            destination: "reporter@example.org", destination_channel: "email"
          )

          refute matched.valid?
          assert_includes matched.errors, :account_not_allowed_for_kind
        end

        def test_provider_inbound_identity_is_opaque_and_never_an_account
          context = RecipientContext.provider_inbound_identity(
            organization_id: 1, channel: "whatsapp", identity_digest: "a" * 64
          )

          assert context.valid?, context.errors.inspect
          refute context.account_lookup_allowed?
          assert_nil context.account_id
          assert_includes RecipientContext.new(
            kind: "provider_inbound_identity", organization_id: 1, channel: "whatsapp", identity_digest: nil
          ).errors, :identity_digest_required
        end

        def test_staff_recipient_carries_an_audience_role
          context = RecipientContext.staff(organization_id: 1, account_id: 3, audience_role: "reports_read")

          assert context.valid?, context.errors.inspect
          assert_equal "reports_read", context.audience_role
          refute RecipientContext.staff(organization_id: 1, account_id: 3, audience_role: nil).valid?
        end

        def test_external_institution_requires_a_destination_and_no_account
          context = RecipientContext.external_institution(
            organization_id: 1, destination: "prijave@example.org", destination_channel: "email", label: "Sistem 48"
          )

          assert context.valid?, context.errors.inspect
          refute context.account_lookup_allowed?
        end

        def test_unknown_recipient_kind_is_invalid_rather_than_permissive
          context = RecipientContext.new(kind: "whoever", organization_id: 1)

          refute context.valid?
          assert_includes context.errors, :unknown_kind
        end

        def test_requested_channels_must_be_recognised
          context = RecipientContext.account(organization_id: 1, account_id: 7, requested_channels: %w(viber carrier_pigeon))

          refute context.valid?
          assert_includes context.errors, :unknown_requested_channel
        end

        def test_context_carries_the_actual_event_and_deadline
          context = RecipientContext.account(
            organization_id: 1, account_id: 7, locale: "sr",
            resource_type: "Decidim::Bih::Report", resource_id: 42,
            classification: "case_private", deadline_at: 1_800_000_000
          )

          assert context.valid?, context.errors.inspect
          assert_equal "Decidim::Bih::Report", context.resource_type
          assert_equal 42, context.resource_id
          assert_equal "case_private", context.classification
          assert_equal 1_800_000_000, context.deadline_at
          assert_equal "sr", context.locale
        end

        def test_missing_context_is_reported_not_invented
          context = RecipientContext.account(organization_id: 1, account_id: 7)

          assert_nil context.resource_type
          assert_nil context.deadline_at
          assert_empty context.requested_channels
        end

        def test_to_h_is_a_plain_serialisable_snapshot_without_raw_identities
          context = RecipientContext.provider_inbound_identity(
            organization_id: 1, channel: "messenger", identity_digest: "b" * 64
          )
          snapshot = context.to_h

          assert_equal "provider_inbound_identity", snapshot.fetch(:kind)
          refute snapshot.has_key?(:destination), "an opaque identity must not be re-exported as a destination"
        end
      end
    end
  end
end

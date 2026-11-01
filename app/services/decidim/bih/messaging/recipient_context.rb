# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Who a message is for, and what it is about.
      #
      # A recipient is NOT always an account. Registration addresses a phone
      # number nobody has verified yet; a report can carry its own contact
      # address with no account behind it; a provider chat gives an opaque
      # identity that is not a phone and not a person we know. Each of those is
      # a legitimate recipient, and none of them may be silently upgraded into
      # an account by matching a phone number or an e-mail address.
      #
      # Deliberately plain Ruby: this contract has to be readable and testable
      # without Rails, and it must never reach into the database by itself.
      class RecipientContext
        KINDS = %w(
          account
          pending_authentication
          anonymous_report_contact
          staff
          external_institution
          provider_inbound_identity
          operator_mailbox
        ).freeze

        # Kinds whose destination is supplied by the request rather than looked
        # up from a stored, proven identity.
        REQUEST_ADDRESSED_KINDS = %w(pending_authentication anonymous_report_contact external_institution operator_mailbox).freeze

        # Only these kinds may be resolved to a Decidim account. The others are
        # addressed directly, and an account match would be a fabrication.
        ACCOUNT_BACKED_KINDS = %w(account staff).freeze

        CHANNELS = %w(bell push email sms viber whatsapp messenger instagram postal web_chat).freeze

        attr_reader :kind, :organization_id, :account_id, :destination, :destination_channel,
                    :channel, :identity_digest, :audience_role, :classification, :locale,
                    :requested_channels, :deadline_at, :resource_type, :resource_id, :label, :metadata

        def self.account(organization_id:, account_id:, **rest)
          new(kind: "account", organization_id:, account_id:, **rest)
        end

        def self.staff(organization_id:, account_id:, audience_role:, **rest)
          new(kind: "staff", organization_id:, account_id:, audience_role:, **rest)
        end

        def self.pending_authentication(organization_id:, destination:, destination_channel: "phone", **rest)
          new(kind: "pending_authentication", organization_id:, destination:, destination_channel:, **rest)
        end

        def self.anonymous_report_contact(organization_id:, destination:, destination_channel:, **rest)
          new(kind: "anonymous_report_contact", organization_id:, destination:, destination_channel:, **rest)
        end

        def self.external_institution(organization_id:, destination:, destination_channel: "email", **rest)
          new(kind: "external_institution", organization_id:, destination:, destination_channel:, **rest)
        end

        def self.operator_mailbox(organization_id:, destination:, **rest)
          new(kind: "operator_mailbox", organization_id:, destination:, destination_channel: "email", **rest)
        end

        def self.provider_inbound_identity(organization_id:, channel:, identity_digest:, **rest)
          new(kind: "provider_inbound_identity", organization_id:, channel:, identity_digest:, **rest)
        end

        # rubocop:disable Metrics/ParameterLists
        def initialize(kind:, organization_id: nil, account_id: nil, destination: nil, destination_channel: nil,
                       channel: nil, identity_digest: nil, audience_role: nil, classification: nil, locale: nil,
                       requested_channels: [], deadline_at: nil, resource_type: nil, resource_id: nil,
                       label: nil, metadata: {})
          @kind = kind.to_s
          @organization_id = organization_id
          @account_id = account_id
          @destination = presence(destination)
          @destination_channel = presence(destination_channel)
          @channel = presence(channel)
          @identity_digest = presence(identity_digest)
          @audience_role = presence(audience_role)
          @classification = presence(classification)
          @locale = presence(locale)
          @requested_channels = Array(requested_channels).map(&:to_s)
          @deadline_at = deadline_at
          @resource_type = presence(resource_type)
          @resource_id = resource_id
          @label = presence(label)
          @metadata = metadata || {}
          @errors = compute_errors
        end
        # rubocop:enable Metrics/ParameterLists

        def errors
          @errors.dup
        end

        def valid?
          @errors.empty?
        end

        # True only for the kinds that legitimately resolve to a stored account.
        # Everything else is addressed as given; a phone or e-mail match must
        # never be used to attach an unrelated account to it.
        def account_lookup_allowed?
          ACCOUNT_BACKED_KINDS.include?(kind)
        end

        # Authentication of an unverified phone uses the validated requested
        # destination. Demanding a prior verified destination here would make
        # registration impossible, so it is false for exactly that kind.
        def requires_verified_destination?
          kind == "account"
        end

        def request_addressed?
          REQUEST_ADDRESSED_KINDS.include?(kind)
        end

        def to_h
          snapshot = {
            kind:,
            organization_id:,
            classification:,
            locale:,
            requested_channels: requested_channels.dup,
            deadline_at:,
            resource_type:,
            resource_id:
          }
          snapshot[:account_id] = account_id if account_lookup_allowed?
          snapshot[:audience_role] = audience_role if audience_role
          snapshot[:destination_channel] = destination_channel if destination_channel
          snapshot[:destination_present] = !destination.nil?
          # An opaque provider identity is carried as a digest and never
          # re-exported as if it were a destination we could address by hand.
          snapshot[:identity_digest] = identity_digest if identity_digest
          snapshot[:channel] = channel if channel
          snapshot
        end

        private

        def presence(value)
          return nil if value.nil?
          return nil if value.respond_to?(:empty?) && value.empty?

          value
        end

        def compute_errors
          errors = []
          errors << :unknown_kind unless KINDS.include?(kind)
          errors << :organization_required if organization_id.nil?
          errors << :unknown_requested_channel unless (requested_channels - CHANNELS).empty?
          return errors unless KINDS.include?(kind)

          errors.concat(kind_errors)
          errors
        end

        def kind_errors
          case kind
          when "account" then account_id.nil? ? [:account_required] : []
          when "staff" then staff_errors
          when "pending_authentication" then destination.nil? ? [:destination_required] : []
          when "anonymous_report_contact", "external_institution", "operator_mailbox" then request_addressed_errors
          when "provider_inbound_identity" then provider_identity_errors
          else []
          end
        end

        def staff_errors
          errors = []
          errors << :account_required if account_id.nil?
          errors << :audience_role_required if audience_role.nil?
          errors
        end

        def request_addressed_errors
          errors = []
          errors << :destination_required if destination.nil?
          errors << :account_not_allowed_for_kind unless account_id.nil?
          errors
        end

        def provider_identity_errors
          errors = []
          errors << :identity_digest_required if identity_digest.nil?
          errors << :channel_required if channel.nil?
          errors << :account_not_allowed_for_kind unless account_id.nil?
          errors
        end
      end
    end
  end
end

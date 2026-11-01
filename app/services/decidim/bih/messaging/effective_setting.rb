# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # What the citizen asked for, what will actually happen, and why they
      # differ — in that order, because a page that shows only the second lies
      # about their choice and a page that shows only the first lies about the
      # outcome.
      #
      # This is the object that prevents the audited defect: the Viber toggle
      # rendered ticked for everybody while the delivery gate said no for 89 of
      # 96, because "absent" meant one thing to the page and another to the
      # sender. Here absent is `requested: nil` with origin "unknown" — it is
      # never a stored no, and it never silently becomes a yes.
      #
      # Deliberately plain Ruby: no ActiveSupport (`blank?`, `presence`), so the
      # pure unit suite can load it with no Rails at all.
      class EffectiveSetting
        # "unrecorded" is not a synonym for "unknown". A core column with a
        # database default records NOTHING about who set it, so a stored value
        # there cannot be presented as a personal choice - that is the same
        # class of claim the audit found on the Viber toggle. "unknown" is
        # reserved for "there is no stored value at all".
        ORIGINS = %w(account organization_default provider_opt_out legacy unrecorded unknown).freeze

        # How a recorded provenance source maps to what the citizen is told.
        PROVENANCE_ORIGINS = {
          "account" => "account",
          "organization_default" => "organization_default",
          "provider_opt_out" => "provider_opt_out",
          "legacy_import" => "legacy",
          "legacy" => "legacy",
          # A stored value whose provenance row says "unknown" is exactly that:
          # stored, with nobody recorded as having stored it.
          "unknown" => "unrecorded",
          # LegacyAdapters#provenance_source says "absent" when there is no key.
          "absent" => "unknown"
        }.freeze

        REASON_KEYS = %w(
          provider_stop
          no_verified_phone
          no_connected_channel
          session_expired
          channel_not_configured
          no_proven_email
          never_chosen
          generic
        ).freeze

        SCOPE = "decidim.bih.communication_settings"

        attr_reader :row, :requested, :effective, :origin, :reason_key

        class << self
          # The one place the four facts about an external topic/channel cell
          # are combined, so the rule is unit-testable without a database.
          #
          #   requested          nil when no key is stored - NOT false
          #   permitted          what the delivery gate says about the key
          #   channel_reason     why the channel itself cannot carry it, or nil
          #   provenance_source  who last wrote the key
          def for_topic_channel(row:, requested:, permitted:, channel_reason:, provenance_source:)
            origin = origin_for(provenance_source, requested)
            effective = permitted && channel_reason.nil?
            new(row:, requested:, effective:, origin:, reason_key: topic_channel_reason(
              requested:, origin:, channel_reason:
            ))
          end

          # An unmapped provenance value is still a stored value, so it is
          # "unrecorded", never silently promoted to "account".
          def origin_for(provenance_source, requested)
            PROVENANCE_ORIGINS.fetch(provenance_source.to_s) { requested.nil? ? "unknown" : "unrecorded" }
          end

          private

          def topic_channel_reason(requested:, origin:, channel_reason:)
            # A provider STOP explains a stored no better than anything else,
            # and it is the only case where a "no" needs explaining at all.
            return "provider_stop" if origin == "provider_opt_out" && requested == false
            # Absence is absence. It is not a refusal, so it is never reported
            # as one, and it is never quietly reported as a yes either.
            return "never_chosen" if requested.nil?
            return channel_reason if requested == true && channel_reason

            nil
          end
        end

        def initialize(row:, requested:, effective:, origin:, reason_key: nil)
          raise ArgumentError, "unknown origin" unless ORIGINS.include?(origin.to_s)

          @row = row
          @requested = requested
          @effective = effective
          @origin = origin.to_s
          @reason_key = blank?(reason_key) ? nil : reason_key.to_s
        end

        def id = row[:id]

        # An absent choice cannot disagree with an outcome: there is nothing to
        # disagree with. Only a stored choice that the sender will not honour
        # counts as a difference the citizen deserves an explanation for.
        def differs? = !requested.nil? && requested != effective

        def personal_choice? = origin == "account"

        def never_chosen? = origin == "unknown"

        def checked? = requested.nil? ? effective == true : requested == true

        # The citizen string is ALWAYS a translation key lookup. Never
        # interpolate the origin or the reason key itself into the page.
        def citizen_reason(locale)
          return nil if reason_key.nil?

          I18n.t("#{SCOPE}.reasons.#{reason_key}", locale:,
                                                   default: [:"#{SCOPE}.reasons.generic", ""])
        end

        def citizen_origin(locale)
          I18n.t("#{SCOPE}.origin.#{origin}", locale:, default: "")
        end

        private

        def blank?(value)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end
    end
  end
end

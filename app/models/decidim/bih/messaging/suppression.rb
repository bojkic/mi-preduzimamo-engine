# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # What a TRANSPORT refuses to carry, scoped to organization, provider,
      # channel and destination identity.
      #
      # This is not a topic choice and must never be stored as one. A provider
      # STOP, a hard bounce and a complaint are refusals by the transport or by
      # a person addressed at that destination; an ordinary "turn this topic back
      # on" in a settings grid does not clear them. Reactivation is recorded with
      # its evidence rather than by deleting the row, and a changed address gets
      # a NEW address version instead of inheriting an unrelated failure.
      #
      # Keyed by tenant + provider + channel + destination DIGEST + address
      # version, never by a delivery id: a delivery id identifies one message,
      # and a refusal is about a destination.
      class Suppression < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_messaging_suppressions"

        CHANNELS = %w(viber whatsapp messenger instagram sms email).freeze
        DESTINATION_KINDS = %w(phone email channel_identity).freeze
        # Five different things, kept five different things. `provider_opt_out`
        # is the provider STOP; `optional_unsubscribe` is a citizen leaving an
        # optional list, which is a weaker statement than a STOP and is the only
        # reason a settings surface may ever record.
        REASONS = %w(provider_opt_out hard_bounce complaint temporary_failure
                     optional_unsubscribe unresolved_legacy_block).freeze
        # A soft failure is a refusal with an expiry: the mailbox was full, the
        # handset was off. It suppresses, and then it stops suppressing by
        # itself — which is why it may never be stored as a hard bounce.
        SELF_EXPIRING_REASONS = %w(temporary_failure).freeze
        SELF_EXPIRY = 72.hours

        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id, optional: true

        validates :provider, presence: true
        validates :channel, inclusion: { in: CHANNELS }
        validates :destination_kind, inclusion: { in: DESTINATION_KINDS }
        validates :reason, inclusion: { in: REASONS }
        validates :destination_digest, :source, :suppressed_at, presence: true
        validates :address_version, numericality: { only_integer: true, greater_than: 0 }

        scope :active, -> { where(reactivated_at: nil) }
        # Active AND still within its own lifetime. A temporary failure that has
        # aged out is still a record of what happened; it just stops blocking.
        scope :blocking, lambda { |now = Time.current|
          active.where("reason NOT IN (:self_expiring) OR COALESCE(occurred_at, suppressed_at) > :cutoff",
                       self_expiring: SELF_EXPIRING_REASONS, cutoff: now - SELF_EXPIRY)
        }

        def self.active_for(organization:, provider:, channel:, destination_digest:)
          active.where(organization:, provider:, channel:, destination_digest:)
                .order(address_version: :desc).first
        end

        # The question the router's pre-send recheck asks. Deliberately narrow:
        # it answers about ONE destination on ONE channel of ONE provider, and a
        # blank digest is "we do not know", never "nothing is suppressed for
        # everybody with no digest".
        def self.blocking_for(organization:, provider:, channel:, destination_digest:, now: Time.current)
          return nil if destination_digest.blank?

          blocking(now).where(organization:, provider:, channel:, destination_digest:)
                       .order(address_version: :desc).first
        end

        def self.blocking?(organization:, provider:, channel:, destination_digest:, now: Time.current)
          !blocking_for(organization:, provider:, channel:, destination_digest:, now:).nil?
        end

        def active?
          reactivated_at.nil?
        end

        def blocking?(now = Time.current)
          return false unless active?
          return true unless SELF_EXPIRING_REASONS.include?(reason)

          (occurred_at || suppressed_at) > (now - SELF_EXPIRY)
        end
      end
    end
  end
end

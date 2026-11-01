# frozen_string_literal: true

module Decidim
  module Bih
    module Viber
      # Records that a Viber sender has proven control of a phone number via an
      # OTP. This is the ONLY persisted artefact of the verification flow: the
      # pending OTP itself lives in Redis (Decidim::Bih::Viber::OtpStore), never
      # in the database.
      #
      # SECURITY: a Linkage means "this Viber sender controls phone X" and,
      # optionally, "this Viber sender IS the Decidim::User at decidim_user_id".
      # The user association is resolved at OTP-verify time by finding the user
      # whose sms authorization unique_id matches the verified phone. It is
      # INTENTIONALLY OPTIONAL: existing phone-only linkages remain valid with a
      # nil user. The user id is used ONLY for goodwill attribution (points,
      # leaderboard) and Viber-first verification — it is NEVER used to start a
      # session or mutate the user account. See Decidim::Bih::Viber::AccountLinking.
      class Linkage < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_viber_linkages"

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        # Optional: resolved at OTP-verify time when a matching sms-authorized
        # user is found in the same org. Nil is valid (phone-only linkage).
        belongs_to :user,
                   class_name: "Decidim::User",
                   foreign_key: "decidim_user_id",
                   optional: true

        # Historical column name: this stores the opaque, channel-specific
        # Viber Bot user ID received from the bot webhook, never a phone/MSISDN
        # or a Viber Business Messages conversation identifier.
        validates :viber_sender, presence: true
        # phone is required when the row is created by the OTP flow (proving phone
        # control). It is intentionally nil for Viber-link-only rows (created by
        # ViberVerifyFlow from a LoginToken), which bind a Viber sender to a
        # Decidim user but do NOT prove phone ownership. A nil phone is treated as
        # "no phone" by attributed_phone, report forwarding, and the privacy sweep.
        # See MakeViberLinkagePhoneNullable migration.
        validates :phone, presence: true, if: :phone_required?
        # Backed by the composite unique index [decidim_organization_id, viber_sender].
        validates :viber_sender, uniqueness: { scope: :decidim_organization_id }

        # True once the OTP has been verified (it always is, on create — the row
        # is only written after a successful verify), kept explicit for clarity.
        def verified?
          verified_at.present?
        end

        # Strips a phone string to its digit representation, matching the format
        # stored in the +phone+ column. Shared with AccountLinking so that the
        # same normalization is always applied — whether storing a new linkage or
        # looking one up from a web-form reporter_phone (e.g. "+387 6X XXX-XXX").
        # Returns nil when the input cannot be a phone (too short/long once stripped).
        def self.normalize_phone(phone)
          digits = phone.to_s.gsub(/\D/, "")
          min = Decidim::Bih::Viber::AccountLinking::MIN_PHONE_DIGITS
          max = Decidim::Bih::Viber::AccountLinking::MAX_PHONE_DIGITS
          return nil unless digits.length.between?(min, max)

          digits
        end

        private

        # Phone is required only when the row has no phone AND no user association.
        # A Viber-link-only row (from ViberVerifyFlow) has phone: nil but a
        # decidim_user_id — that is a valid, intentional state. An OTP-flow row has
        # phone set; phone: nil with no user is never a valid row shape.
        def phone_required?
          phone.blank? && decidim_user_id.blank?
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Viber
      # A verified phone number that may be addressed by Viber Business
      # Messages for a known Decidim user.
      #
      # WHY THIS EXISTS SEPARATELY FROM Linkage: Infobip bills Viber Business
      # Messages and Viber Bot as two different products, and this deployment
      # runs Business Messages only (Decidim::Bih::Config.viber_bot_enabled? is
      # false). Linkage rows are written exclusively by the Bot's OTP flow, so
      # with the Bot off no new Linkage can ever exist and every phone-addressed
      # Viber notification would silently match zero recipients. This table is
      # the Bot-free equivalent.
      #
      # SEMANTICS: a row means "this user proved control of this phone through
      # the platform's SMS verification". It carries no Viber identity and can
      # never be used to authenticate — it is only a delivery address.
      #
      # CONSENT: a row is an address, not a permission. Whether a message is
      # actually sent is decided at send time by
      # Decidim::Bih::NotificationPreferences (mi_city_service_alerts_viber).
      class BusinessContact < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_viber_business_contacts"
        self.filter_attributes = ["phone"]

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :user,
                   class_name: "Decidim::User",
                   foreign_key: "decidim_user_id"

        validates :phone, presence: true
        validates :verified_at, presence: true
        # Backed by the composite unique index [decidim_organization_id, decidim_user_id].
        validates :decidim_user_id, uniqueness: { scope: :decidim_organization_id }

        # Records (or refreshes) the delivery address for +user+ after their
        # phone has been proven. Returns the row, or nil when +phone+ cannot be
        # normalized to a plausible MSISDN.
        #
        # Normalization is shared with Linkage so a user who has both a Bot-era
        # Linkage and a Business contact stores the number identically in both.
        #
        # Never raises: this is called from the SMS-authorization grant path,
        # where failing to record a *notification address* must not roll back
        # the user's actual verification.
        def self.record!(user:, phone:, verified_at: Time.current)
          return if user.blank?

          normalized = Decidim::Bih::Viber::Linkage.normalize_phone(phone)
          return if normalized.blank?

          contact = find_or_initialize_by(
            decidim_organization_id: user.decidim_organization_id,
            decidim_user_id: user.id
          )
          contact.phone = normalized
          contact.verified_at = verified_at
          contact.save!
          contact
        rescue StandardError => e
          Rails.logger.error(
            "[Viber::BusinessContact] could not record contact for user #{user&.id}: " \
            "#{Decidim::Bih::LogRedactor.error_message(e)}"
          )
          nil
        end
      end
    end
  end
end

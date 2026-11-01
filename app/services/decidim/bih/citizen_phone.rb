# frozen_string_literal: true

module Decidim
  module Bih
    # Jedino mjesto koje čita i piše broj telefona građanina.
    #
    # Normalizacija je ista kao u Decidim::Bih::SmsAuthorization (samo "+" i
    # cifre), pa se sačuvani broj poklapa sa onim iz kojeg je izračunat
    # unique_id verifikacije.
    module CitizenPhone
      module_function

      # Upotrebljiv broj za slanje SMS-a, ili nil.
      # NIKAD ne loguje broj — ni u poruci greške.
      def for(user)
        return nil unless user.is_a?(Decidim::User)

        VerifiedPhone.phone_for(user:, organization: user.organization)
      rescue StandardError => e
        Rails.logger.error("[citizen_phone] čitanje palo: #{e.class}")
        nil
      end

      # Zapiši broj poslije uspješne verifikacije. Idempotentno: jedan red po
      # građaninu, novija verifikacija prepisuje stariju.
      # NIKAD ne loguje broj — ni u poruci greške.
      def store!(user, phone)
        normalized = Decidim::Bih::SmsAuthorization.normalize(phone)
        return nil if normalized.blank? || user.blank?

        record = CitizenPhoneRecord.find_or_initialize_by(user:)
        record.organization = user.organization
        record.phone = normalized
        record.verified_at = Time.current
        record.save!
        record
      rescue StandardError => e
        Rails.logger.error(
          "[citizen_phone] upis pao za korisnika #{user&.id}: #{e.class}"
        )
        nil
      end
    end
  end
end

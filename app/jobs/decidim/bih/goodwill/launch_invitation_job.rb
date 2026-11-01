# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Pokušava izdati pozivnicu za lansiranje poslije dodjele bodova.
      # Sav teški posao (prag, zaliha, rok, idempotentnost) radi servis; ovaj
      # job samo razrješava korisnika i pušta isporuku.
      class LaunchInvitationJob < ActiveJob::Base
        queue_as :default

        # Korisnik je mogao biti obrisan između dodjele i izvršenja job-a.
        discard_on ActiveJob::DeserializationError

        def perform(user_id)
          user = Decidim::User.find_by(id: user_id)
          return if user.blank?

          invitation = LaunchInvitation.issue_for(user)
          return if invitation.blank?
          # Samo SVJEŽE izdata pozivnica ide u isporuku — ponovljeni poziv
          # vraća postojeći red i ne smije poslati drugi e-mail.
          return unless invitation.previously_new_record?

          LaunchInvitationDeliveryJob.perform_later(invitation.id)
        rescue StandardError => e
          # Pozivnica nikad ne smije srušiti dodjelu bodova.
          Rails.logger.error("[goodwill] launch invitation job failed: #{e.class}: #{e.message}")
          nil
        end
      end
    end
  end
end

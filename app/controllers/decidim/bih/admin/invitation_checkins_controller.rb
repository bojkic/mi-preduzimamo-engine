# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Provjera ulaznog koda na vratima lansiranja. Kod je JEDNOKRATAN:
      # prvi uspješan pokušaj prebacuje pozivnicu u "fulfilled" i pečatira
      # entry_code_used_at; svaki sljedeći javlja "već iskorišten".
      class InvitationCheckinsController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:reward_fulfillment_checkin) }

        # GET /admin/bih/pozivnice/provjera
        def new
          @result = nil
        end

        # POST /admin/bih/pozivnice/provjera
        def create
          @result = check_in(params[:entry_code].to_s.strip.upcase)
          render :new
        end

        private

        def check_in(code)
          return :unknown if code.blank?

          invitation = Decidim::Bih::Goodwill::RewardFulfillment.find_by(
            organization: current_organization,
            reward_key: Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY,
            entry_code: code
          )
          return :unknown if invitation.blank?
          return :already_used if invitation.entry_code_used_at.present?
          return :no_longer_valid unless invitation.status == "reserved"

          consume!(invitation)
        end

        # Atomično: re-provjera POD bravom (ne samo prije nje), jer se status i
        # entry_code_used_at mogu promijeniti između provjere iznad i brave
        # (npr. sweep za istek 72h roka otkazuje pozivnicu baš u tom trenutku)
        # — dva istovremena skeniranja istog koda zato ne mogu oba proći.
        #
        # Potvrda dolaska NIJE uslov za ulaz: rok od 72h služi da se
        # nepotvrđena pozivnica vrati u zalihu za druge komšije, ne da se
        # gostu zabrani ulaz zbog propuštenog klika. Ali operater mora znati
        # da dolazak nije potvrđen — otud odvojen "valid_unconfirmed" ishod.
        #
        # mark! može odbiti prelaz u "fulfilled" (npr. ako je status u
        # međuvremenu postao terminalan) — njegov povratni rezultat se MORA
        # provjeriti, inače bi operater dobio "važeća" poruku za pozivnicu
        # koja zapravo nije prešla u fulfilled. Kad odbije, vraćamo pečat
        # (ActiveRecord::Rollback) — kod tada NIJE potrošen.
        # Bez `return` iz transakcijskog bloka: u Rails 7 to commituje.
        def consume!(invitation)
          outcome = nil

          Decidim::Bih::Goodwill::RewardFulfillment.transaction do
            invitation.lock!

            if invitation.entry_code_used_at.present?
              outcome = :already_used
            elsif invitation.status != "reserved"
              outcome = :no_longer_valid
            else
              confirmed = invitation.attendance_confirmed_at.present?
              invitation.update!(entry_code_used_at: Time.current)
              transitioned = invitation.mark!(
                "fulfilled",
                by: current_user,
                source: "admin",
                actor_role: "operator",
                metadata: { action: "entry_code_consumed" }
              )

              if transitioned
                outcome = confirmed ? :valid : :valid_unconfirmed
              else
                outcome = :no_longer_valid
                raise ActiveRecord::Rollback
              end
            end
          end

          outcome
        end
      end
    end
  end
end

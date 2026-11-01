# frozen_string_literal: true

module Decidim
  module Bih
    # Potvrda dolaska na lansiranje. Građanin mora biti prijavljen — kod se
    # NIKAD ne prenosi kroz URL, pa ne može procuriti u logove posrednika.
    #
    # Namjerno NE koristi Devise's before_action :authenticate_user! — ova
    # ruta je POST-only (nema GET parnjaka), pa bi Devise-ov redirect poslije
    # prijave (uvijek GET) pukao na grešku rutiranja umjesto da vrati
    # građanina na habu. Ručna provjera (kao u RewardsController#redeem)
    # samo flešuje poruku i preusmjerava na hub bez oslanjanja na Devise-ov
    # sačuvani "vrati me nazad" URL.
    class LaunchInvitationsController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser

      # POST /biceriseno/pozivnica/potvrdi
      def confirm
        user = current_organization_user
        unless user
          flash[:alert] = t(".login_required")
          return redirect_to(decidim_bih.community_hub_path(tab: "nagrade"))
        end

        invitation = Decidim::Bih::Goodwill::RewardFulfillment.find_by(
          organization: current_organization,
          user:,
          reward_key: Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY,
          auto_issued: true
        )

        if invitation.blank?
          flash[:alert] = t(".not_found")
        else
          # Ista logika (i isti redoslijed provjera) kao link iz poruke —
          # Goodwill::LaunchInvitation.confirm_attendance!.
          outcome = Decidim::Bih::Goodwill::LaunchInvitation.confirm_attendance!(invitation, actor: user, via: "hub")
          key = [:confirmed, :already_confirmed].include?(outcome) ? :notice : :alert
          flash[key] = t(".#{outcome}")
        end

        redirect_to decidim_bih.community_hub_path(tab: "nagrade")
      end
    end
  end
end

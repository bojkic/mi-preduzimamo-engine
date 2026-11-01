# frozen_string_literal: true

module Decidim
  module Bih
    # Citizens gift wallet points to local organizations (UserGroups). The org
    # accumulates received points and can later put them to use. Recognition is
    # never moved — gifting costs wallet balance only, not contribution score.
    #
    # GET  /biceriseno/podrzi  -> organizations + the viewer's wallet
    # POST /biceriseno/podrzi  -> gift (signed-in, wallet-guarded)
    class GiftsController < Decidim::ApplicationController
      include Decidim::Bih::GoodwillWallet

      def index
        destination = current_organization_user ? wallet_path(tab: "podrzi", locale: I18n.locale) : community_hub_path(tab: "podrzi", locale: I18n.locale)
        redirect_to destination
      end

      def create
        user = current_organization_user
        unless user
          flash[:alert] = t(".login_required")
          return redirect_to(action: :index)
        end

        response.headers["Cache-Control"] = "private, no-store"
        if params[:confirmation].present?
          payload = confirmation_verifier.verified(params[:confirmation], purpose: "gift")
          raise ArgumentError unless payload && payload["user"] == user.id && payload["organization"] == current_organization.id
          Decidim::Bih::Goodwill::GiftPoints.call(user, payload["recipient"], payload["amount"], request_key: payload["request_key"]) do
            on(:ok) { |recipient, amount| flash[:notice] = t(".gifted", amount:, name: recipient.display_label) }
            on(:insufficient) { flash[:alert] = t(".insufficient") }
            on(:invalid) { flash[:alert] = t(".invalid") }
          end
          return redirect_to(action: :index)
        end

        @recipient = Decidim::Bih::PartnerProfile.goodwill_eligible.where(organization: current_organization).find_by!(id: params[:recipient_id])
        @amount = Decidim::Bih::Goodwill::RequestIdentity.amount(params[:amount])
        Decidim::Bih::Goodwill::RequestIdentity.key("gift", user, params[:request_key])
        @balance_after = wallet_balance - @amount
        return redirect_to({ action: :index }, alert: t(".insufficient")) if @balance_after.negative?

        @confirmation = confirmation_verifier.generate(
          { "user" => user.id, "organization" => current_organization.id, "recipient" => @recipient.id,
            "amount" => @amount, "request_key" => params[:request_key] }, expires_in: 15.minutes, purpose: "gift"
        )
        render :confirm
      rescue ArgumentError, ActiveRecord::RecordNotFound
        redirect_to({ action: :index }, alert: t(".invalid"))
      end

      private

      def confirmation_verifier
        Rails.application.message_verifier("goodwill-gift-confirmation")
      end

      # Org-scoped, matching the wallet/rewards/hub controllers: a wallet is only
      # resolved for a user that belongs to the current organization (previously
      # this used current_user directly — the audited inconsistency).
      def wallet_balance
        wallet_balance_for(current_organization_user)
      end
    end
  end
end

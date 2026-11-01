# frozen_string_literal: true

module Decidim
  module Bih
    # Public rewards catalog + authenticated redemption. Citizens spend wallet
    # points (earned recognition currency) on modest symbolic rewards. The
    # catalog is host-configured; redemption is wallet-guarded server-side so a
    # balance can never go negative.
    #
    # POST /biceriseno/nagrade/redeem/:key -> redeem (requires a signed-in user)
    # GET  /biceriseno/nagrade redirects to the hub (see engine routes)
    class RewardsController < Decidim::ApplicationController
      include Decidim::Bih::GoodwillWallet

      def redeem
        user = current_organization_user
        unless user
          flash[:alert] = t(".login_required")
          return redirect_to(community_hub_path(tab: "nagrade"))
        end

        unless params[:redemption_confirmed] == "1"
          flash[:alert] = t(".confirmation_required")
          return redirect_to(rewards_return_path)
        end
        unless params[:redemption_request_key].to_s.match?(Decidim::Bih::Goodwill::RewardFulfillment::REQUEST_KEY_PATTERN)
          flash[:alert] = t(".invalid")
          return redirect_to(rewards_return_path)
        end

        Decidim::Bih::Goodwill::RedeemReward.call(user, params[:reward_key], params[:redemption_request_key]) do
          on(:ok) do |reward|
            msg = t(".redeemed", reward: reward.name)
            msg = "#{msg} #{reward.fulfillment}" if reward.fulfillment.present?
            flash[:notice] = msg
          end
          on(:insufficient) { flash[:alert] = t(".insufficient") }
          on(:invalid) { flash[:alert] = t(".invalid") }
          on(:auto_issue_only) { flash[:alert] = t(".auto_issue_only") }
          on(:expired) { flash[:alert] = t(".expired") }
          on(:out_of_stock) { flash[:alert] = t(".out_of_stock") }
          on(:already) { |reward| flash[:notice] = t(".already", reward: reward.name) }
        end

        redirect_to(rewards_return_path)
      end

      def cancel
        user = current_organization_user
        return redirect_to(account_overview_path, alert: t(".login_required")) unless user

        fulfillment = Decidim::Bih::Goodwill::RewardFulfillment.find_by(
          id: params[:id], organization: current_organization, user:
        )
        result = Decidim::Bih::Goodwill::CancelRewardRedemption.call(fulfillment:, user:)
        key = [:ok, :already].include?(result) ? :canceled : :cancel_failed
        redirect_to account_overview_path(anchor: "aktivnost"),
                    ([:ok, :already].include?(result) ? { notice: t(".#{key}") } : { alert: t(".#{key}") })
      end

      # GET only previews. The authenticated POST records the explicit request
      # to generate/download the digital artifact, never claimed browser receipt.
      def certificate
        load_certificate!
        response.headers["Cache-Control"] = "private, no-store"
        render :certificate, layout: false
      end

      def download_certificate
        load_certificate!
        document = nil
        @fulfillment.with_lock do
          raise ActiveRecord::RecordNotFound unless @fulfillment.certificate_available?
          document = render_to_string(:certificate, layout: false, formats: [:html], locals: { downloaded: true })
          if @fulfillment.open?
            @fulfillment.mark!("fulfilled", by: current_organization_user, source: "public", actor_role: "citizen",
                               metadata: { action: "certificate_download", delivery_evidence: "download_requested" })
          end
        end
        response.headers["Cache-Control"] = "private, no-store"
        send_data document, type: "text/html; charset=utf-8", disposition: "attachment", filename: "zahvalnica-#{@fulfillment.id}.html"
      end

      private

      def rewards_return_path
        params[:from_wallet] == "1" ? wallet_path(tab: "nagrade", locale: I18n.locale) : community_hub_path(tab: "nagrade", anchor: "nagrade")
      end


      def load_certificate!
        user = current_organization_user
        raise ActiveRecord::RecordNotFound unless user
        @fulfillment = Goodwill::RewardFulfillment.find_by!(id: params[:id], organization: current_organization, user:)
        raise ActiveRecord::RecordNotFound unless @fulfillment.certificate_available?
      end

      def wallet_balance
        wallet_balance_for(current_organization_user)
      end
    end
  end
end

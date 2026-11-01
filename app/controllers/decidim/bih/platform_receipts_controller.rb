# frozen_string_literal: true

module Decidim
  module Bih
    class PlatformReceiptsController < Decidim::ApplicationController
      # The signed, expiring per-delivery capability authorizes only an ACK.
      skip_before_action :verify_authenticity_token, only: :create

      def create
        token = params[:token]
        return head :not_found unless token.is_a?(String) && token.bytesize <= 2048

        receipt = PlatformDelivery.find_signed(token, purpose: :platform_display_receipt)
        return head :not_found unless receipt && receipt.organization == current_organization
        return head :gone if receipt.expires_at <= Time.current

        receipt.acknowledge!("browser_display")
        head :no_content
      end
    end
  end
end

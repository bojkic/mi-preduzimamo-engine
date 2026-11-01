# frozen_string_literal: true

module Decidim
  module Bih
    # Shared Goodwill wallet helpers for the public engagement controllers
    # (wallet / rewards / gifts) and the community hub.
    #
    # Consolidates two pieces of logic that were copy-pasted across those
    # controllers:
    #
    #   * +current_organization_user+ — the signed-in user, but ONLY when they
    #     belong to the current organization (a cross-organization session must
    #     never resolve to a wallet here). Returns nil otherwise.
    #
    #   * +wallet_balance_for+ — the spendable balance of a user's wallet, or nil
    #     when there is no user. The nil (rather than 0) for "no user" is load
    #     bearing: the gifts/hub views guard on +if @balance+ to hide the balance
    #     chrome from anonymous viewers, so a real 0-balance account and "not
    #     signed in" must stay distinguishable.
    #
    # Including controllers must expose +current_organization+ and +current_user+
    # (standard Decidim::ApplicationController).
    module GoodwillWallet
      extend ActiveSupport::Concern
      include Decidim::Bih::CurrentOrganizationUser

      private

      def wallet_balance_for(user)
        return nil unless user

        Decidim::Bih::Goodwill::Account.balance_for(user, current_organization)
      end
    end
  end
end

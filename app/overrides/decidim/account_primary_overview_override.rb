# frozen_string_literal: true

# Make the MI account overview the primary citizen account destination while
# preserving Decidim's original identity/settings form behind an explicit query.
module Decidim
  module Bih
    module AccountPrimaryOverviewOverride
      def show
        return super if account_settings_request?

        redirect_to Decidim::Bih.public_path("moj-nalog")
      end

      private

      def account_settings_request?
        ActiveModel::Type::Boolean.new.cast(params[:settings])
      end
    end
  end
end

Decidim::AccountController.prepend(
  Decidim::Bih::AccountPrimaryOverviewOverride
)

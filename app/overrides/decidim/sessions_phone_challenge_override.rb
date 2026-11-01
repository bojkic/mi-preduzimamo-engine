# frozen_string_literal: true

module Decidim
  module Bih
    module SessionsPhoneChallengeOverride
      def new
        # The canonical sign-in page now also renders the pending phone code
        # form. Keep it out of caches, as on PhoneSessionsController.
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Pragma", "no-cache")
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
        super
      end
    end
  end
end

Decidim::Devise::SessionsController.prepend(Decidim::Bih::SessionsPhoneChallengeOverride)

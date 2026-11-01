# frozen_string_literal: true

module Decidim
  module Bih
    # Guided newcomer onboarding for the MI PRE(D)UZIMAMO! platform.
    #
    # Two presentational, anonymous-safe surfaces (no model reads — like the
    # MI bot showcase, they inherit Decidim::ApplicationController only to get
    # current_organization + the public layout):
    #
    #   GET /biceriseno/vodic       -> #guide       "Šta mogu ovdje?"
    #   GET /biceriseno/verifikacija -> #verification "Zašto verifikacija?"
    #
    # The guide walks a newcomer through the four pillars (report / participate /
    # community points / komšiluk) with a one-line what + why + CTA each, plus a
    # short "kako početi" path. The verification page explains why phone/SMS
    # verification is required and links to the authorizations page.
    class OnboardingController < Decidim::ApplicationController
      def guide; end

      def verification; end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Public, anonymous impact dashboard. It renders only ImpactSummary's
    # aggregate read model; row-level citizen data never reaches the view.
    #
    # GET {public_mount}/uticaj
    class ImpactController < Decidim::ApplicationController
      def index
        @summary = Decidim::Bih::ImpactSummary.new(organization: current_organization).call
      end
    end
  end
end

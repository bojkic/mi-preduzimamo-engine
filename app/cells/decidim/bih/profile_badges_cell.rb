# frozen_string_literal: true

module Decidim
  module Bih
    class ProfileBadgesCell < Decidim::ViewModel
      private

      def public_profile
        @public_profile ||= Decidim::Bih::PublicProfilePresenter.new(user: model, viewer: current_user)
      end

      def current_user
        controller.current_user
      end
    end
  end
end

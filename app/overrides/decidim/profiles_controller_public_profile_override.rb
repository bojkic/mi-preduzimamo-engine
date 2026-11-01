# frozen_string_literal: true

module Decidim
  module Bih
    module ProfilesControllerPublicProfileOverride
      def show
        @content_cell = "decidim/bih/profile_contribution"
        @title_key = "contribution"
        render :show
      end

      def badges
        @content_cell = "decidim/bih/profile_badges"
        @title_key = "badges"
        render :show
      end

      def following
        return super if current_user == profile_holder

        redirect_to profile_path(nickname: params[:nickname].downcase), status: :moved_permanently
      end

      def followers
        redirect_to profile_path(nickname: params[:nickname].downcase), status: :moved_permanently
      end
    end
  end
end

Decidim::ProfilesController.prepend(Decidim::Bih::ProfilesControllerPublicProfileOverride)

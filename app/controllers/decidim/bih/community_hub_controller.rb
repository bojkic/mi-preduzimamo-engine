# frozen_string_literal: true

module Decidim
  module Bih
    # "Bodovi zajedništva" — the single-page engagement hub. Four deep-linkable
    # tabs, selected by ?tab=tabla|nagrade|pozovi|kako (default: tabla).
    #
    # The hub replaces the old standalone leaderboard / rewards / invite / kako
    # pages in the main nav. Those routes remain as 301 redirects so existing
    # links don't break.
    #
    # GET /biceriseno/zajednistvo(?tab=tabla&period=all|month|week)
    class CommunityHubController < Decidim::ApplicationController
      include Decidim::Bih::Concerns::CommunityHubData

      VALID_TABS = %w(tabla trka nagrade pozovi kako podrzi).freeze
      DEFAULT_TAB = "tabla"

      def show
        @tab = params[:tab].presence_in(VALID_TABS) || DEFAULT_TAB
        load_viewer_summary

        load_community_tab(@tab)
      end

      private

      def load_viewer_summary
        user = current_organization_user
        return unless user

        @viewer_account = Decidim::Bih::Goodwill::Account.find_by(
          organization: current_organization,
          owner_type: user.class.base_class.name,
          owner_id: user.id
        )
        @viewer_contribution = @viewer_account&.contribution_score || 0
        @viewer_balance = @viewer_account&.balance || 0
        @viewer_level = Decidim::Bih::Goodwill::Levels.for(@viewer_contribution)
      end
    end
  end
end

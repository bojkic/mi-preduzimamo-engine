# frozen_string_literal: true

module Decidim
  module Bih
    # Public recognition leaderboard constants used by CommunityHubData concern
    # and the hub view. The standalone show action was removed — the route at
    # GET /biceriseno/tabla is a 301 redirect to the hub (see engine routes).
    class LeaderboardController < Decidim::ApplicationController
      TOP_N = 25
      PERIODS = %w(all month week).freeze
      CACHE_TTL = 2.minutes
    end
  end
end

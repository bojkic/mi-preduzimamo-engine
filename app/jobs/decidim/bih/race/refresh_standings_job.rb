# frozen_string_literal: true

module Decidim
  module Bih
    module Race
      # Background refresh of the cached race standings. Safe to enqueue often —
      # Standings#refresh! carries its own 10-minute interval guard, so a flood
      # of enqueues still results in at most one recomputation per interval.
      class RefreshStandingsJob < ApplicationJob
        queue_as :default

        def perform(organization_id)
          organization = Decidim::Organization.find_by(id: organization_id)
          return unless organization

          Standings.new(organization).refresh!
        end
      end
    end
  end
end

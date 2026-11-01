# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      # One read-only SQL snapshot, then the same deterministic calculator used
      # for immutable final evidence. Public pages only read cached Standings.
      class Scorer
        def initialize(organization:, config: nil)
          @organization = organization
          @config = config || Config.new(organization:)
        end
        def rows
          Calculator.new(SnapshotBuilder.new(organization: @organization, config: @config).call).rows
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    class ReportShadowSweepJob < ApplicationJob
      queue_as :reports
      def perform(organization_id)
        organization = Decidim::Organization.find_by(id: organization_id)
        ReportShadowSweep.new(organization).call if organization
      end
    end
  end
end

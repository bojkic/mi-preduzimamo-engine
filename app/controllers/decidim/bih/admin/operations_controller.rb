# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class OperationsController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:operations_read) }

        def index
          summary = Decidim::Bih::Admin::OperationsSummary.new(organization: current_organization)
          @admin_dashboard_metrics = summary.metrics_by_item
          @admin_workflow_handoffs = summary.handoffs
        end
      end
    end
  end
end

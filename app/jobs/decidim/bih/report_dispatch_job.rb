# frozen_string_literal: true

module Decidim
  module Bih
    class ReportDispatchJob < ApplicationJob
      queue_as :reports

      def perform(id)
        dispatch = ReportDispatch.find_by(id:)
        ReportDispatching.deliver!(dispatch) if dispatch
      end
    end
  end
end

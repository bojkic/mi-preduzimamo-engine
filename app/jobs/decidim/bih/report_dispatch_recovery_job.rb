# frozen_string_literal: true

module Decidim
  module Bih
    class ReportDispatchRecoveryJob < ApplicationJob
      queue_as :reports

      def perform(id)
        ReportDispatching.recover!(scope: ReportDispatch.where(id:))
      end
    end
  end
end

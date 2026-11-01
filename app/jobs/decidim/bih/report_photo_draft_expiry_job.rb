# frozen_string_literal: true

module Decidim
  module Bih
    class ReportPhotoDraftExpiryJob < ApplicationJob
      queue_as :reports

      def perform(id)
        ReportPhotoDraft.find_by(id:)&.expire!
      rescue ActiveRecord::RecordNotFound
        # Another expiry worker already removed this draft.
        nil
      end
    end
  end
end

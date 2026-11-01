# frozen_string_literal: true

module Decidim
  module Bih
    class KomsilukPhotoDraftExpiryJob < ApplicationJob
      queue_as :default

      def perform(draft_id)
        KomsilukPhotoDraft.find_by(id: draft_id)&.expire!
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    class ChannelConnectionChallenge < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_channel_connection_challenges"
      self.filter_attributes += [:token_digest, :confirmation_digest, :recipient_ciphertext]
    end
  end
end

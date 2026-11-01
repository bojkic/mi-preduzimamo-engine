# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Raised when an owner tries to spend (gift / regrant / redeem) more points
      # than their wallet balance. The spend is rejected atomically — no entries
      # are written — so a wallet can never go negative.
      class InsufficientBalanceError < StandardError; end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Raised inside RedeemReward when the reward's stock cap has been reached.
      # Caught by the command and broadcast as :out_of_stock so the controller
      # can render a friendly flash without a 500.
      class StockExhaustedError < StandardError; end
    end
  end
end

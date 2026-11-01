# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Raised when something attempts to mutate or destroy a persisted ledger
      # transaction or entry. The goodwill ledger is append-only; corrections are
      # made by posting a reversing transaction.
      class AppendOnlyError < StandardError; end
    end
  end
end

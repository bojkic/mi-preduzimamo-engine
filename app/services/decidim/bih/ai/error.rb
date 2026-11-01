# frozen_string_literal: true

module Decidim
  module Bih
    module Ai
      # Raised on AI transport/non-200/parse failure, or when a call is
      # attempted while the client is unconfigured.
      class Error < StandardError; end
    end
  end
end

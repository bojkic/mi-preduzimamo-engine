# frozen_string_literal: true

module Decidim
  module Bih
    module Odoo
      # Raised on an Odoo JSON-RPC transport/auth/fault failure.
      class Error < StandardError; end
    end
  end
end

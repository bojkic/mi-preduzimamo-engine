# frozen_string_literal: true

module Decidim
  module Bih
    # Generic signed blob/representation URLs are public bearer routes, including
    # proxy routes that call download directly. Private report downloads use
    # their existing authorized controllers instead.
    module PrivateBlobRoutes
      private

      def set_blob
        super
        head :not_found if @blob&.service_name == "report_private"
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Keep privacy and rate-limit matching consistent across Decidim's locale
    # prefixes. This does not rewrite the request or change Rails routing.
    module LocalePath
      module_function

      def strip(path, locales: Decidim.available_locales)
        path = path.to_s
        prefix, rest = path.delete_prefix("/").split("/", 2)
        return path unless locales.map(&:to_s).include?(prefix)

        rest ? "/#{rest}" : "/"
      end
    end
  end
end

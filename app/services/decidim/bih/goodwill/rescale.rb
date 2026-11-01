# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # The September migration has completed. Its unbounded action-ratio
      # algorithm cannot safely distinguish contemporary awards from old ones.
      # Keep the name so stale scripts fail explicitly, before any lookup/write.
      module Rescale
        class RetiredOperation < StandardError; end
        MESSAGE = "The historical September 2026 rescale is retired. Use a reviewed source-specific correction manifest; do not rescale current awards."
        module_function

        def run!(_organization, dry_run: true)
          raise RetiredOperation, MESSAGE
        end

        def apply!(*_arguments)
          raise RetiredOperation, MESSAGE
        end
      end
    end
  end
end

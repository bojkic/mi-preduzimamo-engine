# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Which rake mode argument means "write".
      #
      # Extracted from the rake task so the DRY-RUN DEFAULT is a tested
      # property rather than a line someone has to read carefully. The split
      # decides which komšiluci compete for 3.000 KM, so an accidental write
      # over a locked or already-published split is the failure that matters:
      # anything that is not exactly "apply" or "force" must stay read-only.
      module ZoneModes
        WRITE = "apply"
        FORCE = "force"

        module_function

        def write?(mode)
          mode.is_a?(String) && [WRITE, FORCE].include?(mode)
        end

        def force?(mode)
          mode.is_a?(String) && mode == FORCE
        end
      end
    end
  end
end

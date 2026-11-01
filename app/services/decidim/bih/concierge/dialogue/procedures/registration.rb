# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        module Procedures
          module Registration
            def self.call(turn)
              return turn.registration_information if turn.registration_information_request?

              turn.handoff
            end
          end
        end
      end
    end
  end
end

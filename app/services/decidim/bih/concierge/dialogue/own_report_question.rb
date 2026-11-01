# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Selection, never identity: the host still requires a trusted actor
        # and scopes every record query to that actor and organization.
        module OwnReportQuestion
          module_function

          def limit(text)
            return unless text.is_a?(String) && text.length <= 160

            query = Text.fold(text)
            return 3 if list?(query)
            return 1 if latest?(query)

            nil
          end

          def latest?(query)
            query.match?(/\A(?:(?:pokazi(?: mi)?|prikazi(?: mi)?|status|koji je status|kakav je status|sta je sa?) )?moj(?:a|u|e|om) (?:posljednj|poslednj|zadnj)(?:a|u|e|om) prijav(?:a|u|e|om)\z/) ||
              query.match?(/\A(?:(?:show(?: me)?|status of|what is the status of) )?my (?:last|latest|most recent) report\z/)
          end

          def reference_missing?(text)
            /\Anemam\s+(?:(?:njen|njegov|taj|tajni)\s+)?(?:broj|oznaku)(?:\s+prijave)?(?:\s+kod\s+sebe)?\z/.match?(Text.fold(text.to_s))
          end

          def correction?(text)
            query = Text.fold(text.to_s)
            /\A(?:(?:to|ovo)\s+)?nije\s+korisno\s+(?:ne\s+pitam\s+kako\s+(?:napraviti|podnijeti)\s+novu\s+prijavu|pitam\s+(?:za|o)\s+status\w*\s+(?:moj\w*\s+)?prijav\w*)\z/.match?(query)
          end

          def list?(query)
            return true if /\A(?:gdje|gde)\s+su\s+moja\s+prijavljena\s+ostecenja\z/.match?(query)
            # "All/to date" selects the existing bounded own-report list; it
            # never broadens the host's actor/tenant scope or three-row limit.
            query.match?(/\A(?:(?:pokazi(?: mi)?|prikazi(?: mi)?|koje su) )?(?:sve )?moje (?:(?:posljednje|poslednje|zadnje|dosadasnje|prethodne|ranije) )?prijave\z|\Astatus (?:svih )?mojih (?:(?:posljednjih|poslednjih|zadnjih|dosadasnjih|prethodnih|ranijih) )?prijava\z/) ||
              query.match?(/\A(?:(?:show(?: me)?|status of) )?(?:all )?my (?:(?:recent|latest|last|previous|past) )?reports(?: so far)?\z/)
          end
        end
      end
    end
  end
end

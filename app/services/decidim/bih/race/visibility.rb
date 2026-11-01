# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      module Visibility
        module_function
        def visible?(organization)
          edition = Edition.for(organization)
          edition.nil? || edition.scores_visible?
        end
        def version(organization)
          Edition.for(organization)&.visibility_version || 0
        end
        def change!(organization, visible:, actor:, reason:)
          Review.authorize!(organization, actor)
          raise ArgumentError, "reason required" if reason.to_s.strip.empty?
          edition = Edition.ensure_for!(organization)
          edition.with_lock do
            return edition if edition.scores_visible == visible
            old = edition.scores_visible
            edition.update!(scores_visible: visible, visibility_version: edition.visibility_version + 1)
            edition.record!("visibility", actor:, before: old, after: visible, reason:)
          end
          edition
        end
      end
    end
  end
end

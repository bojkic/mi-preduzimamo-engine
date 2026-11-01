# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Compatibility adapter for Goodwill organization ownership.
      #
      # Existing balances live on legacy Decidim user-group owners. New partner
      # profiles can also own ledger accounts directly, but during v1 migration a
      # profile linked to a legacy group should read/write through that group so
      # no balance disappears.
      module PartnerOwner
        module_function

        def owner_for(profile)
          return profile unless profile.respond_to?(:legacy_user_group)

          profile.legacy_user_group || profile
        end

        def profile_for(owner, organization:)
          return owner if owner.is_a?(Decidim::Bih::PartnerProfile)
          return nil unless owner.respond_to?(:id)

          Decidim::Bih::PartnerProfile.find_by(
            organization:,
            legacy_user_group_id: owner.id
          )
        end

        def display_name(owner)
          if owner.is_a?(Decidim::Bih::PartnerProfile)
            owner.display_name
          else
            owner.try(:name).presence || owner.try(:nickname).presence || "##{owner.id}"
          end
        end
      end
    end
  end
end

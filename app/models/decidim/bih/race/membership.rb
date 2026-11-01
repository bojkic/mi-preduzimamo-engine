# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      class Membership < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_race_memberships"
        belongs_to :edition, class_name: "Decidim::Bih::Race::Edition"
        belongs_to :komsiluk, class_name: "Decidim::Bih::LocalArea"
        validates :decidim_user_id, uniqueness: { scope: :edition_id }

        def self.capture!(edition, profile, provenance: "first_recorded")
          return unless profile.komsiluk_id && profile.assigned_at && profile.decidim_user_id
          user = profile.user
          return unless user && user.decidim_organization_id == edition.decidim_organization_id
          granted = Decidim::Authorization.where(user:, name: "sms").where.not(granted_at: nil).minimum(:granted_at)
          # An unverified selection is not a qualifying contest area.
          return unless granted && granted <= Time.current
          member = find_or_create_by!(edition:, decidim_user_id: user.id) do |record|
            record.komsiluk_id = profile.komsiluk_id
            record.assigned_at = profile.assigned_at
            record.qualified_at = [granted, profile.assigned_at].max if granted
            record.provenance = provenance
          end
          if !member.qualified_at && granted
            member.update!(qualified_at: [granted, member.assigned_at].max)
          end
          member
        end
      end
    end
  end
end

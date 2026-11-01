# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Foundation-owned membership storage preserves group administration
      # and goodwill regrant permissions when Decidim 0.32 drops its old table.
      class GroupMembership < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_group_memberships"

        belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
        belongs_to :group, class_name: "Decidim::User", foreign_key: :decidim_user_group_id

        # Group admins (allowed to re-grant the group's received goodwill).
        scope :admins, -> { where(role: %w(creator admin)) }
        # Active members (excludes pending "requested" join requests).
        scope :member, -> { where(role: %w(creator admin member)) }

        # Fail closed during incomplete installation or migration.
        def self.available?
          connection.table_exists?(table_name)
        rescue StandardError
          false
        end
      end
    end
  end
end

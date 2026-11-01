# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # A tenant's versioned defaults and its supported class/channel set.
      #
      # Kept per organization on purpose: this engine is reusable, and a
      # Bijeljina activation decision must not silently opt another host into
      # the same policy. An organization with no active row has no policy, and
      # callers fall back to their own defaults rather than to Bijeljina's.
      class OrganizationPolicy < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_messaging_organization_policies"

        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id

        validates :policy_version, presence: true
        validates :effective_from, presence: true
        validates :policy_version, uniqueness: { scope: :decidim_organization_id }

        scope :active, -> { where(active: true) }

        def self.active_for(organization)
          return nil if organization.nil?

          active.where(organization:).order(effective_from: :desc).first
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Durable proposal identity. Existing per-term credits are represented by
    # legacy_transaction_id; neither an edit nor another term pays that proposal.
    class VolunteerProposalAward < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_volunteer_proposal_awards"

      belongs_to :organization, class_name: "Decidim::Organization",
               foreign_key: "decidim_organization_id"

      validates :proposal_identity, presence: true,
               uniqueness: { scope: :decidim_organization_id }
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Links the referrer (who invited) to the invitee (who joined). One per
      # invitee; the referrer is rewarded once the invitee verifies.
      class Referral < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_referrals"

        STATUSES = %w(pending rewarded).freeze

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :referrer, class_name: "Decidim::User"
        belongs_to :invitee, class_name: "Decidim::User"

        belongs_to :ledger_transaction, class_name: "Decidim::Bih::Goodwill::Transaction", foreign_key: :transaction_id, optional: true
        validate :actors_share_organization

        validates :status, inclusion: { in: STATUSES }
        validates :invitee_id, uniqueness: true

        scope :pending, -> { where(status: "pending") }
        scope :rewarded, -> { where(status: "rewarded") }

        private

        def actors_share_organization
          errors.add(:base, :invalid) if referrer && invitee &&
            (referrer.organization != organization || invitee.organization != organization || referrer.id == invitee.id)
        end
      end
    end
  end
end

# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      class AwardAdmission < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_award_admissions"
        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        belongs_to :account, class_name: "Decidim::Bih::Goodwill::Account"
        belongs_to :ledger_transaction, class_name: "Decidim::Bih::Goodwill::Transaction", foreign_key: :transaction_id, optional: true
        validates :source_key, :action, :occurred_at, :period_start, presence: true
        validates :outcome, inclusion: { in: %w(awarded capped disabled ineligible duplicate) }
        validate :same_organization
        scope :awarded, -> { where(outcome: "awarded") }
        private
        def same_organization
          errors.add(:base, :invalid) unless account && account.organization == organization &&
            (!ledger_transaction || ledger_transaction.organization == organization)
        end
      end
    end
  end
end

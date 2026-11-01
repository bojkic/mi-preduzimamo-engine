# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      # Immutable recognition journal. Wallet settlement is a separate record.
      class CreditCorrection < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_credit_corrections"
        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        belongs_to :account, class_name: "Decidim::Bih::Goodwill::Account"
        belongs_to :original_transaction, class_name: "Decidim::Bih::Goodwill::Transaction"
        belongs_to :actor, class_name: "Decidim::User", optional: true
        has_one :settlement, class_name: "Decidim::Bih::Goodwill::CreditSettlement", dependent: :restrict_with_exception
        validates :source_key, :decision_version, :reason, :earned_at, presence: true
        validates :decision_version, uniqueness: { scope: [:decidim_organization_id, :source_key] }
        validate :consistent_source
        before_update :immutable!
        before_destroy :immutable!
        private
        def consistent_source
          return unless account && original_transaction && organization
          errors.add(:base, :invalid) unless account.organization == organization && original_transaction.organization == organization &&
            original_transaction.kind == "earn" && (!actor || actor.organization == organization)
        end
        def immutable!
          raise AppendOnlyError, "recognition corrections are append-only"
        end
      end
    end
  end
end

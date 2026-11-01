# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # A single signed posting (positive=credit, negative=debit) belonging to one
      # transaction and one account. APPEND-ONLY: once created, an entry can never
      # be updated or destroyed; corrections are made via a reversing transaction.
      #
      # The transaction association is named :ledger_transaction (not :transaction)
      # to avoid shadowing ActiveRecord's instance-level #transaction, which
      # Decidim's mixed-in concerns may rely on.
      class Entry < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_entries"

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :ledger_transaction,
                   class_name: "Decidim::Bih::Goodwill::Transaction",
                   foreign_key: "decidim_bih_goodwill_transaction_id",
                   inverse_of: :entries

        belongs_to :account,
                   class_name: "Decidim::Bih::Goodwill::Account",
                   foreign_key: "decidim_bih_goodwill_account_id",
                   inverse_of: :entries

        validates :amount, presence: true,
                           numericality: { only_integer: true, other_than: 0 }
        validate :tenant_boundaries_match

        before_update :prevent_mutation
        before_destroy :prevent_destroy

        private

        def tenant_boundaries_match
          return unless organization

          errors.add(:account, :invalid) if account && account.organization != organization
          errors.add(:ledger_transaction, :invalid) if ledger_transaction && ledger_transaction.organization != organization
        end

        def prevent_mutation
          raise Decidim::Bih::Goodwill::AppendOnlyError, "goodwill ledger entries are append-only"
        end

        def prevent_destroy
          raise Decidim::Bih::Goodwill::AppendOnlyError, "goodwill ledger entries are append-only"
        end
      end
    end
  end
end

# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      class CreditSettlement < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_credit_settlements"
        belongs_to :credit_correction, class_name: "Decidim::Bih::Goodwill::CreditCorrection"
        belongs_to :ledger_transaction, class_name: "Decidim::Bih::Goodwill::Transaction", foreign_key: :transaction_id, optional: true
        belongs_to :settled_by, class_name: "Decidim::User", optional: true
        validates :status, inclusion: { in: %w(pending settled admin_pending superseded) }
        scope :admin_pending, -> { where(status: "admin_pending") }
      end
    end
  end
end

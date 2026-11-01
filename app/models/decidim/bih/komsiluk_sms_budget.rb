# frozen_string_literal: true

module Decidim
  module Bih
    class KomsilukSmsBudget < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_sms_budgets"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
    end
  end
end

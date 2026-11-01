# frozen_string_literal: true

module Decidim
  module Bih
    class CaseUsageDay < Decidim::ApplicationRecord
      self.table_name = 'decidim_bih_case_usage_days'
      # The unique database index arbitrates concurrent creation. An application
      # uniqueness validator would raise RecordInvalid before create_or_find_by!
      # can rescue RecordNotUnique and return the already-created day row.
      validates :day, presence: true
    end
  end
end

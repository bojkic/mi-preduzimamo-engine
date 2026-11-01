# frozen_string_literal: true

module Decidim
  module Bih
    # One reversible expression of help, never a booking or membership list.
    class KomsilukHelpResponse < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_help_responses"
      belongs_to :post, class_name: "Decidim::Bih::KomsilukPost"
      belongs_to :user, class_name: "Decidim::User"
      validates :user_id, uniqueness: { scope: :post_id }
      scope :active, -> { where(withdrawn_at: nil) }
    end
  end
end

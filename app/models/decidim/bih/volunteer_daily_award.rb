# frozen_string_literal: true

module Decidim
  module Bih
    # One base volunteering award per citizen and Sarajevo work date. The row
    # survives corrections; version advances only after a fully reversed day.
    class VolunteerDailyAward < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_volunteer_daily_awards"

      belongs_to :organization, class_name: "Decidim::Organization",
               foreign_key: "decidim_organization_id"
      belongs_to :user, class_name: "Decidim::User",
               foreign_key: "decidim_user_id"

      validates :work_date, presence: true,
               uniqueness: { scope: [:decidim_organization_id, :decidim_user_id] }
      validates :version, numericality: { only_integer: true, greater_than: 0 }
    end
  end
end

# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      class Event < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_race_events"
        belongs_to :edition, class_name: "Decidim::Bih::Race::Edition"
        validates :kind, presence: true
        def readonly? = persisted?
      end
    end
  end
end

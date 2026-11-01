# frozen_string_literal: true

module Decidim
  module Bih
    module Race
      # One cached row of the race standing. Written only by Race::Standings.
      class Standing < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_race_standings"

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :komsiluk,
                   class_name: "Decidim::Bih::LocalArea",
                   optional: true

        scope :live, -> { where(final: false) }
        scope :final_snapshot, -> { where(final: true) }
        scope :in_zone, ->(zone) { where(zona: zone) }
        scope :ranked, -> { order(:rank_overall) }

        # The komšiluk's public name in the active locale. Nil-safe so a deleted
        # reference area can never blow up the public page.
        def display_name
          komsiluk&.translated_name || slug_for_test
        end

        def slug_for_test
          komsiluk&.slug
        end
      end
    end
  end
end

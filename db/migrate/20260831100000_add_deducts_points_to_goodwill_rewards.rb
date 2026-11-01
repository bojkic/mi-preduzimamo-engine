# frozen_string_literal: true

# Nagrada može biti PRAG umjesto kupovine: dosegneš je i dobiješ je, bez
# skidanja bodova. Postojeće nagrade zadržavaju staro ponašanje (default true),
# pa se ništa ne mijenja za katalog koji već radi.
class AddDeductsPointsToGoodwillRewards < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_goodwill_rewards, :deducts_points, :boolean,
               null: false, default: true
    # Kada je true, nagrada se izdaje automatski u trenutku prelaska praga,
    # bez ručne potvrde operatora i bez klika građanina.
    add_column :decidim_bih_goodwill_rewards, :auto_issue_at_threshold, :boolean,
               null: false, default: false
  end
end

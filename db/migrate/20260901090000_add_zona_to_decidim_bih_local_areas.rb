# frozen_string_literal: true

# Permanent grad/selo category for the neighbourhood race. Computed ONCE from
# polygon overlap with the Bijeljina settlement frame and then locked — the race
# must never recompute a komšiluk's league mid-competition.
class AddZonaToDecidimBihLocalAreas < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_local_areas, :zona, :string
    add_index :decidim_bih_local_areas,
              [:decidim_organization_id, :kind, :zona],
              name: "idx_bih_local_areas_zona"
  end
end

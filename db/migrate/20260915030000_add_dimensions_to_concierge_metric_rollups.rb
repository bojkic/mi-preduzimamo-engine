# frozen_string_literal: true

# Legacy rows stay unclassified. Never manufacture historical facets, synthetic
# provenance or capture-time releases from a rollup's checkout stamp.
class AddDimensionsToConciergeMetricRollups < ActiveRecord::Migration[7.2]
  def up
    change_table :decidim_bih_concierge_metric_rollups, bulk: true do |table|
      table.string :facet, null: false, default: "unknown"
      table.string :traffic_kind, null: false, default: "unclassified"
    end
    remove_index :decidim_bih_concierge_metric_rollups, name: "idx_bih_concierge_metric_rollups_unique"
    add_index :decidim_bih_concierge_metric_rollups,
              [:decidim_organization_id, :day, :kind, :topic, :label, :latency_bucket],
              unique: true, nulls_not_distinct: true, where: "kind <> 'answer_detail'", name: "idx_bih_concierge_metric_rollups_unique"
    add_index :decidim_bih_concierge_metric_rollups,
              [:decidim_organization_id, :day, :kind, :topic, :label, :latency_bucket, :facet, :traffic_kind, :release_sha, :prompt_version],
              unique: true, nulls_not_distinct: true, where: "kind = 'answer_detail'", name: "idx_bih_concierge_metric_detail_unique"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Dimensioned counters require an explicit preservation/aggregation plan before rollback"
  end
end

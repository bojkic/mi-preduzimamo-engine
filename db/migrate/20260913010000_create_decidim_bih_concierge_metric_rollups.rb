# frozen_string_literal: true

# Nightly rollup of the 48-hour Redis chat metrics (answer outcomes, read
# latency histograms, understanding/rendering stage timings) into a durable,
# aggregate-only table so launch history stops evaporating with the cache TTL.
#
# Privacy contract: counts by day, kind, bounded topic, bounded label and fixed
# latency bucket only. No text, identifiers, coordinates or channel senders.
# `latency_bucket` is NULL for answer rows, so the unique index treats NULLs as
# equal — otherwise the nightly upsert could stack duplicate answer rows.
class CreateDecidimBihConciergeMetricRollups < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_concierge_metric_rollups do |t|
      t.references :decidim_organization, null: false, foreign_key: { to_table: :decidim_organizations }, index: false
      t.date :day, null: false
      t.string :kind, null: false
      t.string :topic, null: false
      t.string :label, null: false
      t.bigint :count, null: false, default: 0
      t.string :latency_bucket
      t.string :release_sha, limit: 40
      t.integer :prompt_version
      t.timestamps
    end
    add_index :decidim_bih_concierge_metric_rollups,
              [:decidim_organization_id, :day, :kind, :topic, :label, :latency_bucket],
              unique: true, nulls_not_distinct: true, name: "idx_bih_concierge_metric_rollups_unique"
    add_index :decidim_bih_concierge_metric_rollups, [:decidim_organization_id, :day],
              name: "idx_bih_concierge_metric_rollups_org_day"
    add_check_constraint :decidim_bih_concierge_metric_rollups, "count >= 0", name: "chk_bih_concierge_metric_rollups_count"
  end
end

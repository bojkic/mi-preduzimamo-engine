# frozen_string_literal: true

# Round 25 (W4.2 / W4.4) — a generic per-organization, namespaced key/value
# store for operator-editable configuration that previously lived only in the
# host initializer or ENV:
#
#   - goodwill earning schedule / daily caps / season start (W4.2)
#   - Sistem 48 forwarding targets — central intake + per-category email (W4.4)
#
# Design: ONE row per (organization, namespace, key), with a jsonb `value`.
# jsonb keeps it shape-agnostic (an integer cap, a string email, an ISO date
# string) and lets readers treat the whole store uniformly. The table is
# ADDITIVE and REVERSIBLE; while it is EMPTY for an organization every reader
# falls back to DEFAULTS → config/ENV, so this deploy changes NOTHING until an
# operator edits a value.
class CreateDecidimBihSettings < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_settings do |t|
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_settings_org" }

      # Logical group, e.g. "goodwill_schedule", "goodwill_caps",
      # "goodwill_season", "sistem48_routing". Keeps unrelated settings from
      # colliding on key and lets a reader load a whole namespace cheaply.
      t.string :namespace, null: false

      # Setting key within the namespace, e.g. "report" (a schedule action),
      # "central_intake", or a category symbol like "putevi".
      t.string :key, null: false

      # The stored value as jsonb (number / string / null). Nullable so a row
      # can represent an explicit "no value" if ever needed; readers treat
      # blank as absent.
      t.jsonb :value

      t.timestamps
    end

    # One row per (organization, namespace, key); readers upsert by this tuple.
    add_index :decidim_bih_settings,
              [:decidim_organization_id, :namespace, :key],
              unique: true,
              name: "idx_bih_settings_org_ns_key"
  end
end

# frozen_string_literal: true

# Geographic hierarchy for the Komšiluk belonging subsystem.
# Two-level tree: Mjesna zajednica (MZ, kind="mz") → Komšiluk (kind="komsiluk").
# Polygon data is stored as GeoJSON jsonb; no PostGIS dependency.
class CreateDecidimBihLocalAreas < ActiveRecord::Migration[7.2]
  def up
    create_table :decidim_bih_local_areas do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }

      # Hierarchical kind: "mz" (top) or "komsiluk" (child).
      t.string :kind, null: false

      # Self-referential parent: null for MZ records, the MZ id for komšiluci.
      t.bigint :parent_id

      # Translatable name: {"sr" => "Centar", "bs" => "Centar", ...}
      t.jsonb :name, null: false, default: {}

      # URL-friendly identifier, unique per organisation.
      t.string :slug, null: false

      # GeoJSON geometry (Polygon or MultiPolygon) as plain jsonb.
      t.jsonb :boundary

      # Approximate centroid for default map view — computed on import.
      t.float :centroid_lat
      t.float :centroid_lon

      t.timestamps
    end

    # Tenant-scoped kind lookup (most common query).
    add_index :decidim_bih_local_areas,
              [:decidim_organization_id, :kind],
              name: "idx_bih_local_areas_on_org_and_kind"

    # Tree traversal: find children of a given parent.
    add_index :decidim_bih_local_areas,
              :parent_id,
              name: "idx_bih_local_areas_on_parent_id"

    # Unique slug per tenant.
    add_index :decidim_bih_local_areas,
              [:decidim_organization_id, :slug],
              unique: true,
              name: "idx_bih_local_areas_on_org_and_slug"

    # Self-referential FK: komsiluk.parent_id → local_areas.id (nullable).
    add_foreign_key :decidim_bih_local_areas,
                    :decidim_bih_local_areas,
                    column: :parent_id,
                    name: "fk_bih_local_areas_parent"
  end

  def down
    remove_foreign_key :decidim_bih_local_areas,
                       name: "fk_bih_local_areas_parent"
    drop_table :decidim_bih_local_areas
  end
end

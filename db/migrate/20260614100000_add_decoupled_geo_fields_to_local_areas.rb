# frozen_string_literal: true

# Revises the LocalArea geo model to decouple komšiluk from MZ:
#
#   - komšiluk is no longer a child of an MZ in the tree; parent_id is left
#     in place (unused) for backward-compatibility but is no longer required
#     or populated by the importer.
#
#   MZ-facing new columns:
#     predsjednik  — name of the council president (savjet)
#     telefon      — contact phone for the MZ council
#     metadata     — jsonb bag for GIS export fields:
#                    { povrsina_m2, obim_m, naziv_gis, izvor, … }
#
#   Komšiluk-facing new columns:
#     primary_mz_slug      — slug of the MZ holding the largest share of this
#                            komšiluk's area (computed, nullable)
#     overlapping_mz_slugs — jsonb array of slugs of every MZ the komšiluk
#                            intersects (computed by decidim_bih:geo:compute_relations)
class AddDecoupledGeoFieldsToLocalAreas < ActiveRecord::Migration[7.2]
  def up
    # MZ-facing fields
    add_column :decidim_bih_local_areas, :predsjednik, :string
    add_column :decidim_bih_local_areas, :telefon, :string
    add_column :decidim_bih_local_areas, :metadata, :jsonb, default: {}

    # Komšiluk-facing relation fields (computed by RelationsComputer)
    add_column :decidim_bih_local_areas, :primary_mz_slug, :string
    add_column :decidim_bih_local_areas, :overlapping_mz_slugs, :jsonb, default: []

    # Index for fast primary_mz_slug lookups (e.g. "all komsiluci whose primary MZ is X")
    add_index :decidim_bih_local_areas,
              :primary_mz_slug,
              name: "idx_bih_local_areas_on_primary_mz_slug"
  end

  def down
    remove_index :decidim_bih_local_areas, name: "idx_bih_local_areas_on_primary_mz_slug"
    remove_column :decidim_bih_local_areas, :overlapping_mz_slugs
    remove_column :decidim_bih_local_areas, :primary_mz_slug
    remove_column :decidim_bih_local_areas, :metadata
    remove_column :decidim_bih_local_areas, :telefon
    remove_column :decidim_bih_local_areas, :predsjednik
  end
end

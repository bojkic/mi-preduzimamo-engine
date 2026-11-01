# frozen_string_literal: true

# The original CreateDecidimBihKomsilukPosts migration had t.references with
# foreign_key: true (which auto-creates an unnamed FK) AND an explicit
# add_foreign_key named "fk_bih_komsiluk_posts_org" for the same column. The
# explicit named one is the duplicate; remove it here so the schema has a
# single organization FK on this table.
class RemoveDuplicateOrgFkFromKomsilukPosts < ActiveRecord::Migration[7.2]
  def up
    # Only remove if the duplicate named FK still exists (safe for fresh deploys
    # where the fixed original migration was run and this FK was never added).
    return unless foreign_key_exists?(:decidim_bih_komsiluk_posts, name: "fk_bih_komsiluk_posts_org")

    remove_foreign_key :decidim_bih_komsiluk_posts, name: "fk_bih_komsiluk_posts_org"
  end

  def down
    # Re-add only if it's not already there (idempotent rollback).
    return if foreign_key_exists?(:decidim_bih_komsiluk_posts, name: "fk_bih_komsiluk_posts_org")

    add_foreign_key :decidim_bih_komsiluk_posts,
                    :decidim_organizations,
                    column: :decidim_organization_id,
                    name: "fk_bih_komsiluk_posts_org"
  end
end

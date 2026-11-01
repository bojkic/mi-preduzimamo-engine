# frozen_string_literal: true

# Komšiluk board posts — short local notices from citizens to their own neighbourhood.
# Moderation is post-moderation (visible immediately) with flag-based auto-hide.
# Author FK uses on_delete: :nullify so deleting a Decidim user orphans the post
# (anonymises the author) without cascading destruction of community content.
class CreateDecidimBihKomsilukPosts < ActiveRecord::Migration[7.2]
  def up
    create_table :decidim_bih_komsiluk_posts do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }

      # Author — nullable; nullified on user deletion (anonymises but preserves content).
      t.bigint :decidim_user_id

      # Komšiluk this post belongs to.
      t.bigint :komsiluk_id, null: false

      # Post category: lost_pet | safety | activity | general
      t.string :category, null: false, default: "general"

      t.string :title, null: false
      t.text :body

      # Lifecycle status: open | closed | expired | hidden
      t.string :status, null: false, default: "open"

      # Expiry: auto-set by model (30d for lost_pet/safety; nil for others).
      # Author may set up to 90d for non-urgent.
      t.datetime :expires_at
      t.datetime :closed_at
      t.datetime :hidden_at

      # Denormalised flag counter for threshold-based auto-hide.
      t.integer :flagged_count, null: false, default: 0

      t.timestamps
    end

    # Tenant + komšiluk + status — the primary visibility query.
    add_index :decidim_bih_komsiluk_posts,
              [:decidim_organization_id, :komsiluk_id, :status],
              name: "idx_bih_komsiluk_posts_on_org_komsiluk_status"

    # Author look-up (e.g. "my posts").
    add_index :decidim_bih_komsiluk_posts,
              :decidim_user_id,
              name: "idx_bih_komsiluk_posts_on_user"

    # Author FK: nullify on user deletion so orphaned posts survive.
    add_foreign_key :decidim_bih_komsiluk_posts,
                    :decidim_users,
                    column: :decidim_user_id,
                    on_delete: :nullify,
                    name: "fk_bih_komsiluk_posts_user"

    add_foreign_key :decidim_bih_komsiluk_posts,
                    :decidim_bih_local_areas,
                    column: :komsiluk_id,
                    name: "fk_bih_komsiluk_posts_komsiluk"
  end

  def down
    remove_foreign_key :decidim_bih_komsiluk_posts, name: "fk_bih_komsiluk_posts_user"
    remove_foreign_key :decidim_bih_komsiluk_posts, name: "fk_bih_komsiluk_posts_komsiluk"
    drop_table :decidim_bih_komsiluk_posts
  end
end

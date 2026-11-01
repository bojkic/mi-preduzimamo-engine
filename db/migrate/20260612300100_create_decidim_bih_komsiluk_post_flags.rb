# frozen_string_literal: true

# One flag per user per post — drives the auto-hide threshold.
# Unique index (post_id, user_id) enforces idempotency at the DB level.
class CreateDecidimBihKomsilukPostFlags < ActiveRecord::Migration[7.2]
  def up
    create_table :decidim_bih_komsiluk_post_flags do |t|
      t.bigint :decidim_bih_komsiluk_post_id, null: false
      t.bigint :decidim_user_id, null: false

      t.timestamps
    end

    # Idempotency: one flag per user per post.
    add_index :decidim_bih_komsiluk_post_flags,
              [:decidim_bih_komsiluk_post_id, :decidim_user_id],
              unique: true,
              name: "idx_bih_komsiluk_post_flags_unique"

    add_foreign_key :decidim_bih_komsiluk_post_flags,
                    :decidim_bih_komsiluk_posts,
                    column: :decidim_bih_komsiluk_post_id,
                    on_delete: :cascade,
                    name: "fk_bih_komsiluk_post_flags_post"

    add_foreign_key :decidim_bih_komsiluk_post_flags,
                    :decidim_users,
                    column: :decidim_user_id,
                    on_delete: :cascade,
                    name: "fk_bih_komsiluk_post_flags_user"
  end

  def down
    remove_foreign_key :decidim_bih_komsiluk_post_flags, name: "fk_bih_komsiluk_post_flags_post"
    remove_foreign_key :decidim_bih_komsiluk_post_flags, name: "fk_bih_komsiluk_post_flags_user"
    drop_table :decidim_bih_komsiluk_post_flags
  end
end

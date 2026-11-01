# frozen_string_literal: true

class ExpandKomsilukBoards < ActiveRecord::Migration[7.2]
  def change
    change_table :decidim_bih_komsiluk_posts, bulk: true do |t|
      t.string :origin, null: false, default: "legacy"
      t.integer :content_revision, null: false, default: 1
      t.string :publication_key
      t.jsonb :details, null: false, default: {}
      t.datetime :published_at
      t.string :review_state, null: false, default: "unreviewed"
      t.integer :lock_version, null: false, default: 0
    end
    add_index :decidim_bih_komsiluk_posts, [:decidim_organization_id, :komsiluk_id, :created_at, :id], name: "idx_komsiluk_board_feed"
    add_index :decidim_bih_komsiluk_posts, :publication_key
    add_index :decidim_bih_komsiluk_posts, [:decidim_organization_id, :komsiluk_id, :publication_key], unique: true, where: "publication_key IS NOT NULL",
                                                                                                       name: "idx_komsiluk_publication_placement"
    add_index :decidim_bih_komsiluk_posts, [:decidim_organization_id, :review_state], name: "idx_komsiluk_board_review"

    create_table :decidim_bih_komsiluk_post_revisions do |t|
      t.references :post, null: false, foreign_key: { to_table: :decidim_bih_komsiluk_posts, on_delete: :cascade }, index: false
      t.references :actor, foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.integer :content_revision, null: false
      t.jsonb :snapshot, null: false, default: {}
      t.boolean :notified, null: false, default: false
      t.timestamps
      t.index [:post_id, :content_revision], unique: true, name: "idx_komsiluk_post_revision"
    end

    create_table :decidim_bih_komsiluk_help_responses do |t|
      t.references :post, null: false, foreign_key: { to_table: :decidim_bih_komsiluk_posts, on_delete: :cascade }, index: false
      t.references :user, null: false, foreign_key: { to_table: :decidim_users, on_delete: :cascade }
      t.datetime :withdrawn_at
      t.timestamps
      t.index [:post_id, :user_id], unique: true, name: "idx_komsiluk_help_response"
    end

    create_table :decidim_bih_komsiluk_photo_drafts do |t|
      t.references :organization, null: false, foreign_key: { to_table: :decidim_organizations, on_delete: :cascade }
      t.references :user, null: false, foreign_key: { to_table: :decidim_users, on_delete: :cascade }
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :expires_at
    end

    reversible do |dir|
      dir.up do
        # Historical content acquires no publication/delivery effect. Missing
        # authors are deliberately not treated as proof of an official origin.
        execute <<~SQL.squish
          UPDATE decidim_bih_komsiluk_posts SET published_at = created_at,
            review_state = CASE WHEN status = 'hidden' OR flagged_count > 0 THEN 'pending' ELSE 'unreviewed' END
        SQL
      end
    end
  end
end

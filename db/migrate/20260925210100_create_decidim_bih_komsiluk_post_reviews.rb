# frozen_string_literal: true

class CreateDecidimBihKomsilukPostReviews < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_komsiluk_post_reviews do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "idx_board_reviews_org" }
      t.bigint :decidim_bih_komsiluk_post_id, null: false
      t.bigint :reviewer_id
      t.string :action, null: false
      t.string :reason, null: false
      t.string :previous_status, null: false
      t.string :resulting_status, null: false
      t.integer :content_revision, null: false
      t.integer :flagged_count, null: false, default: 0
      t.timestamps
    end
    add_index :decidim_bih_komsiluk_post_reviews, [:decidim_bih_komsiluk_post_id, :created_at], name: "idx_board_reviews_post_time"
    add_foreign_key :decidim_bih_komsiluk_post_reviews, :decidim_bih_komsiluk_posts, column: :decidim_bih_komsiluk_post_id, on_delete: :cascade
    add_foreign_key :decidim_bih_komsiluk_post_reviews, :decidim_users, column: :reviewer_id, on_delete: :nullify
  end
end

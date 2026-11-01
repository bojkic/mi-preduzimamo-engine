# frozen_string_literal: true

# Stores metadata-only feedback for web concierge answers. It deliberately keeps
# raw citizen messages, reply text, IP addresses and user agents out of the table.
class CreateDecidimBihConciergeFeedbacks < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_concierge_feedbacks do |t|
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_concierge_feedbacks_org" }
      t.references :decidim_user,
                   null: true,
                   foreign_key: { to_table: :decidim_users },
                   index: { name: "idx_bih_concierge_feedbacks_user" }
      t.string :reply_id, null: false
      t.string :session_digest, null: false
      t.string :value, null: false
      t.string :locale
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :decidim_bih_concierge_feedbacks,
              [:decidim_organization_id, :reply_id, :session_digest],
              unique: true,
              name: "idx_bih_concierge_feedbacks_once"
    add_index :decidim_bih_concierge_feedbacks,
              [:decidim_organization_id, :created_at],
              name: "idx_bih_concierge_feedbacks_org_created"
    add_check_constraint :decidim_bih_concierge_feedbacks,
                         "value IN ('helpful', 'not_helpful')",
                         name: "chk_bih_concierge_feedback_value"
  end
end

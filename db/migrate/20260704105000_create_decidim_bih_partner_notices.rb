# frozen_string_literal: true

# Public notices published by verified organizations.
#
# Owner decision for v1: verified public bodies and institutions may publish
# official notices directly. Other verified organizations may publish updates,
# but only institution/public_body rows should be labelled official.
class CreateDecidimBihPartnerNotices < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_partner_notices do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :partner_profile,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_bih_partner_profiles }
      t.references :author,
                   null: true,
                   index: { name: "idx_bih_partner_notices_author" },
                   foreign_key: { to_table: :decidim_users }
      t.string :title, null: false
      t.text :body, null: false
      t.string :notice_type, null: false, default: "update"
      t.datetime :published_at
      t.datetime :expires_at

      t.timestamps
    end

    add_index :decidim_bih_partner_notices,
              [:decidim_organization_id, :published_at],
              name: "idx_bih_partner_notices_org_published"
    add_index :decidim_bih_partner_notices,
              [:partner_profile_id, :published_at],
              name: "idx_bih_partner_notices_profile_published"
  end
end

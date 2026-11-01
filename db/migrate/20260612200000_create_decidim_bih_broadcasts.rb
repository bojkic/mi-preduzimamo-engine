# frozen_string_literal: true

# Audit record for operator-initiated Komšiluk broadcasts (Wave B2).
# One row per send; immutable after creation — append-only audit trail.
# The sent_by_id FK uses :nullify so deleting an admin user never blocks.
class CreateDecidimBihBroadcasts < ActiveRecord::Migration[7.2]
  def up
    create_table :decidim_bih_broadcasts do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }

      # The geographic area (MZ or Komšiluk) targeted.
      t.bigint :local_area_id, null: false

      # The admin who sent the broadcast. Nullable via :nullify so deleting an
      # admin never cascades into this audit table.
      t.bigint :sent_by_id

      # The message text composed by the operator.
      t.text :message, null: false

      # Delivery channels as a JSON array, e.g. ["bell"] or ["bell", "viber"].
      t.string :channels, null: false, default: "bell"

      # How many recipient users were actually resolved at send time.
      t.integer :recipients_count, null: false, default: 0

      t.timestamps
    end

    # Tenant-scoped list of broadcasts (admin audit list).
    add_index :decidim_bih_broadcasts,
              [:decidim_organization_id, :created_at],
              name: "idx_bih_broadcasts_on_org_and_created_at"

    # FK: area must exist.
    add_foreign_key :decidim_bih_broadcasts,
                    :decidim_bih_local_areas,
                    column: :local_area_id,
                    name: "fk_bih_broadcasts_local_area"

    # FK: sent_by nullable, nullify on user deletion.
    add_foreign_key :decidim_bih_broadcasts,
                    :decidim_users,
                    column: :sent_by_id,
                    on_delete: :nullify,
                    name: "fk_bih_broadcasts_sent_by"
  end

  def down
    remove_foreign_key :decidim_bih_broadcasts, name: "fk_bih_broadcasts_sent_by"
    remove_foreign_key :decidim_bih_broadcasts, name: "fk_bih_broadcasts_local_area"
    drop_table :decidim_bih_broadcasts
  end
end

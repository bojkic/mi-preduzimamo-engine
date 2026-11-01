# frozen_string_literal: true

# Run before Decidim 0.32 removes its legacy membership table. The paired host
# schedules the removal after this migration; external hosts must preserve this
# ordering when copying or renumbering upstream migrations.
class PreserveGoodwillGroupMemberships < ActiveRecord::Migration[8.1]
  def up
    create_table :decidim_bih_goodwill_group_memberships do |t|
      t.integer :decidim_user_id, null: false
      t.integer :decidim_user_group_id, null: false
      t.string :role, default: "requested", null: false
      t.timestamps precision: nil
    end
    add_index :decidim_bih_goodwill_group_memberships, :decidim_user_id, name: "idx_bih_group_members_user"
    add_index :decidim_bih_goodwill_group_memberships, [:decidim_user_group_id, :decidim_user_id], unique: true, name: "idx_bih_group_members_pair"
    add_index :decidim_bih_goodwill_group_memberships, [:role, :decidim_user_group_id], unique: true,
              where: "role = 'creator'", name: "idx_bih_group_members_creator"
    return unless table_exists?(:decidim_user_group_memberships)

    execute <<~SQL
      INSERT INTO decidim_bih_goodwill_group_memberships
        (id, decidim_user_id, decidim_user_group_id, role, created_at, updated_at)
      SELECT id, decidim_user_id, decidim_user_group_id, role, created_at, updated_at
      FROM decidim_user_group_memberships
    SQL
    connection.reset_pk_sequence!("decidim_bih_goodwill_group_memberships")
    expected = select_value("SELECT COUNT(*) FROM decidim_user_group_memberships").to_i
    actual = select_value("SELECT COUNT(*) FROM decidim_bih_goodwill_group_memberships").to_i
    raise "Goodwill membership preservation count mismatch" unless expected == actual
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Preserved group permissions must not be dropped automatically"
  end
end

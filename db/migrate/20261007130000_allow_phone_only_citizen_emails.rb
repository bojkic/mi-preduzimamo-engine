# frozen_string_literal: true

class AllowPhoneOnlyCitizenEmails < ActiveRecord::Migration[7.2]
  INDEX = "index_decidim_users_on_email_and_decidim_organization_id"
  TEMP_INDEX = "index_decidim_users_email_transition"
  BASE = "deleted_at IS NULL AND managed = false AND type = 'Decidim::User'"

  def up
    replace_index("#{BASE} AND email IS NOT NULL AND email <> ''")
  end

  def down
    phone_only = select_value("SELECT EXISTS (SELECT 1 FROM decidim_users WHERE #{BASE} AND extended_data->>'mi_phone_only_registration' = 'true')")
    raise ActiveRecord::IrreversibleMigration, "Phone-only citizens exist; keep compatible account code and the partial email index" if phone_only

    duplicates = select_value("SELECT EXISTS (SELECT 1 FROM decidim_users WHERE #{BASE} GROUP BY email, decidim_organization_id HAVING count(*) > 1)")
    raise ActiveRecord::IrreversibleMigration, "Phone-only accounts share an empty email; keep the partial index until those accounts are safely migrated" if duplicates

    replace_index(BASE)
  end

  private

  def replace_index(predicate)
    execute "SET LOCAL lock_timeout = '5s'"
    execute "SET LOCAL statement_timeout = '60s'"
    add_index :decidim_users, [:email, :decidim_organization_id], unique: true, where: predicate, name: TEMP_INDEX
    candidate = connection.indexes(:decidim_users).find { |index| index.name == TEMP_INDEX }
    raise ActiveRecord::MigrationError, "Replacement email index was not created" unless candidate&.unique && candidate.columns == %w(email decidim_organization_id)

    remove_index :decidim_users, name: INDEX
    rename_index :decidim_users, TEMP_INDEX, INDEX
  end
end

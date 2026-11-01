# frozen_string_literal: true

# Private, operator-reviewed submissions from verified partner profiles. An
# approved submission is materialized as one native Decidim Budgets project;
# the submission itself never becomes the public donation record.
class CreateDecidimBihPartnerProjectSubmissions < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_partner_project_submissions do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :partner_profile,
                   null: false,
                   index: { name: "idx_bih_project_submissions_profile" },
                   foreign_key: { to_table: :decidim_bih_partner_profiles, on_delete: :restrict }
      t.references :decidim_user,
                   null: true,
                   index: { name: "idx_bih_project_submissions_user" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :reviewed_by,
                   null: true,
                   index: { name: "idx_bih_project_submissions_reviewer" },
                   foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :decidim_budgets_project,
                   null: true,
                   index: false,
                   foreign_key: { to_table: :decidim_budgets_projects, on_delete: :nullify }

      t.string :title, null: false
      t.text :description, null: false
      t.bigint :budget_amount, null: false
      t.string :address
      t.date :starts_on
      t.date :ends_on
      t.string :review_status, null: false, default: "draft"
      t.datetime :submitted_at
      t.datetime :reviewed_at
      t.text :rejection_reason
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :decidim_bih_partner_project_submissions,
              [:decidim_organization_id, :review_status, :created_at],
              name: "idx_bih_project_submissions_queue"
    add_index :decidim_bih_partner_project_submissions,
              [:decidim_organization_id, :decidim_budgets_project_id],
              unique: true,
              where: "decidim_budgets_project_id IS NOT NULL",
              name: "idx_bih_project_submissions_project"
  end
end

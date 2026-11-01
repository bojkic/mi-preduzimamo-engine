# frozen_string_literal: true

class CreateDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_reports do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      t.string :reference, null: false
      t.text :description, null: false

      t.string :category
      t.string :department
      t.string :severity
      t.string :ai_summary

      t.string :status, null: false, default: "primljeno"

      t.string :address
      t.float :latitude
      t.float :longitude

      t.string :reporter_email
      t.string :reporter_phone

      t.boolean :anonymous, null: false, default: false

      t.datetime :forwarded_at
      t.string :sistem48_reference

      t.timestamps
    end

    # Per-organization uniqueness: references restart at BR-<year>-0001 for each
    # org, so the unique constraint must be scoped to the org (Decidim is
    # multi-tenant). This composite index also backs the scoped model validation.
    add_index :decidim_bih_reports, [:decidim_organization_id, :reference], unique: true
    add_index :decidim_bih_reports, :status
  end
end

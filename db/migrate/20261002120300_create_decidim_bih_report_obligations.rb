# frozen_string_literal: true
class CreateDecidimBihReportObligations < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_obligations do |t|
      t.references :report, null: false, foreign_key: { to_table: :decidim_bih_reports }
      t.string :kind, null: false
      t.string :actor, null: false
      t.string :state, null: false, default: "open"
      t.datetime :due_at
      t.datetime :reminded_at
      t.references :source, polymorphic: true, index: { name: "idx_report_obligations_source_8243f7" }
      t.references :fulfilled_by, polymorphic: true, index: { name: "idx_report_obligations_fulfilled_by_3bb29a" }
      t.string :policy_key
      t.string :effect_key
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :decidim_bih_report_obligations, :effect_key, unique: true, where: "effect_key IS NOT NULL"
    add_index :decidim_bih_report_obligations, [:report_id, :state, :due_at], name: "index_report_obligations_open_due"
  end
end

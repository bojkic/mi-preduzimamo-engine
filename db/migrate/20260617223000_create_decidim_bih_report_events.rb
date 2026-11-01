# frozen_string_literal: true

# Append-only, PII-minimized audit events for the admin report triage workflow.
# The report row remains the state snapshot; this table records what happened
# over time without copying citizen descriptions, contacts, addresses, or
# internal note bodies into an operator-visible history stream.
class CreateDecidimBihReportEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_report_events do |t|
      t.references :decidim_bih_report,
                   null: false,
                   foreign_key: { to_table: :decidim_bih_reports },
                   index: { name: "idx_bih_report_events_report" }
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_report_events_org" }
      t.references :decidim_user,
                   null: true,
                   foreign_key: { to_table: :decidim_users },
                   index: { name: "idx_bih_report_events_actor" }
      t.string :event_type, null: false
      t.string :source, null: false
      t.string :actor_role
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_report_events,
              [:decidim_bih_report_id, :occurred_at, :id],
              name: "idx_bih_report_events_report_occurred"
    add_index :decidim_bih_report_events,
              [:decidim_organization_id, :event_type, :occurred_at],
              name: "idx_bih_report_events_org_type_occurred"
  end
end

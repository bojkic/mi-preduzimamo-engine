# frozen_string_literal: true

# Append-only, PII-minimized audit events for BIH operator actions.
#
# The row records who acted, which role/capability was used, the target resource
# identity, and bounded structured metadata. It must not store message bodies,
# report descriptions, addresses, contact details, recipient lists, provider
# payloads, raw params, request metadata, or internal note text.
class CreateDecidimBihOperatorAuditEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_operator_audit_events do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_user,
                   null: true,
                   index: { name: "idx_bih_operator_audit_actor" },
                   foreign_key: { to_table: :decidim_users }
      t.string :role
      t.string :permission
      t.string :event_type, null: false
      t.string :resource_type
      t.bigint :resource_id
      t.datetime :occurred_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_operator_audit_events,
              [:decidim_organization_id, :occurred_at, :id],
              name: "idx_bih_operator_audit_org_time"
    add_index :decidim_bih_operator_audit_events,
              [:decidim_organization_id, :event_type, :occurred_at],
              name: "idx_bih_operator_audit_org_type_time"
    add_index :decidim_bih_operator_audit_events,
              [:resource_type, :resource_id, :occurred_at],
              name: "idx_bih_operator_audit_resource_time"
  end
end

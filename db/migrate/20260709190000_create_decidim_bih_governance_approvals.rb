# frozen_string_literal: true

# Append-only, PII-minimized approval records for operational governance.
#
# The row proves that an owner/admin reviewed a bounded evidence summary for a
# release, Viber launch, backup/restore, cron maintenance, or privacy-retention
# workflow. It must not store raw command output, shell history, provider
# payloads, backup paths, dump URLs, contact details, tokens, or secrets.
class CreateDecidimBihGovernanceApprovals < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_governance_approvals do |t|
      t.references :decidim_organization,
                   null: false,
                   index: { name: "idx_bih_governance_approvals_org" },
                   foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_user,
                   null: false,
                   index: { name: "idx_bih_governance_approvals_actor" },
                   foreign_key: { to_table: :decidim_users }
      t.references :operator_audit_event,
                   null: true,
                   index: { name: "idx_bih_governance_approvals_audit" },
                   foreign_key: { to_table: :decidim_bih_operator_audit_events }
      t.string :governance_kind, null: false
      t.string :approval_role, null: false
      t.string :status, null: false
      t.string :scope_key
      t.string :app_sha
      t.string :engine_sha
      t.text :evidence_summary, null: false
      t.string :evidence_digest, null: false
      t.datetime :approved_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_governance_approvals,
              [:decidim_organization_id, :governance_kind, :approved_at, :id],
              name: "idx_bih_governance_approvals_org_kind_time"
    add_index :decidim_bih_governance_approvals,
              [:decidim_organization_id, :status, :approved_at],
              name: "idx_bih_governance_approvals_org_status_time"
  end
end

# frozen_string_literal: true

class CreateDecidimBihGovernanceApprovalAttestations < ActiveRecord::Migration[7.2]
  def change
    # Append-only proof of independent release approval. Exact release evidence
    # stays on the linked PII-minimized governance approval record.
    create_table :decidim_bih_governance_approval_attestations do |t|
      t.references :decidim_organization, null: false,
                                            foreign_key: { to_table: :decidim_organizations },
                                            index: { name: "idx_bih_release_attestations_org" }
      t.references :governance_approval, null: false,
                                           foreign_key: { to_table: :decidim_bih_governance_approvals },
                                           index: { unique: true, name: "idx_bih_release_attestations_approval" }
      t.references :decidim_user, null: false,
                                  foreign_key: { to_table: :decidim_users },
                                  index: { name: "idx_bih_release_attestations_user" }
      t.references :operator_audit_event,
                   foreign_key: { to_table: :decidim_bih_operator_audit_events },
                   index: { unique: true, name: "idx_bih_release_attestations_audit" }
      t.string :approval_role, null: false
      t.datetime :attested_at, null: false
      t.timestamps
    end

    add_index :decidim_bih_governance_approval_attestations,
              [:decidim_organization_id, :attested_at, :id],
              name: "idx_bih_release_attestations_org_time"
  end
end

# frozen_string_literal: true

class AddReleaseControlsToGovernanceApprovals < ActiveRecord::Migration[7.2]
  def change
    add_reference :decidim_bih_governance_approvals,
                  :secondary_approver,
                  null: true,
                  index: { name: "idx_bih_governance_secondary_approver" },
                  foreign_key: { to_table: :decidim_users }
    add_column :decidim_bih_governance_approvals, :secondary_approval_role, :string
    add_column :decidim_bih_governance_approvals, :restart_window_starts_at, :datetime
    add_column :decidim_bih_governance_approvals, :restart_window_ends_at, :datetime
    add_column :decidim_bih_governance_approvals, :local_fast_gate_status, :string
    add_column :decidim_bih_governance_approvals, :local_full_gate_status, :string
    add_column :decidim_bih_governance_approvals, :external_ci_status, :string
    add_column :decidim_bih_governance_approvals, :branch_protection_status, :string
    add_column :decidim_bih_governance_approvals, :backup_health_status, :string
    add_column :decidim_bih_governance_approvals, :restore_smoke_status, :string
    add_column :decidim_bih_governance_approvals, :backup_manifest_digest, :string
    add_column :decidim_bih_governance_approvals, :migration_state, :string

    add_index :decidim_bih_governance_approvals,
              [:decidim_organization_id, :governance_kind, :app_sha, :engine_sha],
              name: "idx_bih_governance_release_shas"
  end
end

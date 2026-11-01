# frozen_string_literal: true

# Matched-giving (R13): a mutable status record (NOT in the append-only ledger)
# capturing a request to match an organization/group's received goodwill with a
# real-world micro-grant. The actual grant stays a MANUAL LFBN bookkeeping step
# in Odoo — this table only records the request + admin decision (pending →
# approved/rejected). Owner is polymorphic (the group/org account owner).
class CreateDecidimBihGoodwillMatchRequests < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_goodwill_match_requests do |t|
      t.references :decidim_organization,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :decidim_organizations }

      # The beneficiary whose received goodwill is being matched (a group/org,
      # i.e. a Decidim::User). Polymorphic to stay decoupled from the STI type.
      t.references :owner, polymorphic: true, null: false,
                           index: { name: "idx_bih_goodwill_match_requests_on_owner" }

      t.integer :points, null: false, default: 0

      # pending | approved | rejected
      t.string :status, null: false, default: "pending"

      t.references :created_by,
                   null: true,
                   index: { name: "idx_bih_goodwill_match_requests_on_created_by" },
                   foreign_key: { to_table: :decidim_users }

      t.references :decided_by,
                   null: true,
                   index: { name: "idx_bih_goodwill_match_requests_on_decided_by" },
                   foreign_key: { to_table: :decidim_users }

      t.datetime :decided_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end
  end
end

# frozen_string_literal: true

# Supports the bounded admin queue for citizen-created volunteer opportunities
# awaiting review: org + oldest pending first.
class AddPendingReviewIndexToDecidimBihVolunteerOpportunities < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = "idx_bih_volunteer_opps_org_pending_review"

  def change
    add_index :decidim_bih_volunteer_opportunities,
              [:decidim_organization_id, :created_at, :id],
              where: "active = false AND review_status = 'pending'",
              name: INDEX_NAME,
              algorithm: :concurrently,
              if_not_exists: true
  end
end

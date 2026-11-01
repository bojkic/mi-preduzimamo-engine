# frozen_string_literal: true

# Store human review reasons for rejected volunteer opportunity proposals and
# rejected volunteer-hour logs. These are mutable workflow records, not ledger
# records; point awards remain gated by approval/verification services.
class AddRejectionReasonsToDecidimBihVolunteering < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_opportunities, :rejection_reason, :text
    add_column :decidim_bih_volunteer_logs, :rejection_reason, :text
  end
end

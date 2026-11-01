# frozen_string_literal: true

# Enrich volunteer opportunities ("missions") with scheduling and logistics
# detail so the public list can show WHEN/WHERE and admins can categorise and
# cap sign-ups. All columns are NULLABLE — existing opportunities and the
# minimal "just a title" create path keep working unchanged.
class AddDetailsToBihVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_opportunities, :starts_at, :datetime
    add_column :decidim_bih_volunteer_opportunities, :location, :string
    add_column :decidim_bih_volunteer_opportunities, :category, :string
    add_column :decidim_bih_volunteer_opportunities, :capacity, :integer
  end
end

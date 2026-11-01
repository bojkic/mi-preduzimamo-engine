# frozen_string_literal: true

# Optionally groups a people/skills opportunity under the same native project
# as its donation link and non-cash needs. Existing opportunities remain valid.
class AddBudgetProjectToDecidimBihVolunteerOpportunities < ActiveRecord::Migration[7.2]
  def change
    add_reference :decidim_bih_volunteer_opportunities,
                  :decidim_budgets_project,
                  null: true,
                  index: { name: "idx_bih_volunteer_opportunities_project" },
                  foreign_key: { to_table: :decidim_budgets_projects, on_delete: :nullify }
  end
end

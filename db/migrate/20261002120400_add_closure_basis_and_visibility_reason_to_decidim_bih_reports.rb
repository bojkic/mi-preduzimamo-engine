# frozen_string_literal: true
class AddClosureBasisAndVisibilityReasonToDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_reports, :closure_basis, :string
    add_column :decidim_bih_reports, :removed_from_public_reason, :string
  end
end

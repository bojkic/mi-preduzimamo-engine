# frozen_string_literal: true

class AddStatusNoteToDecidimBihReports < ActiveRecord::Migration[7.2]
  def up
    add_column :decidim_bih_reports, :status_note, :text unless column_exists?(:decidim_bih_reports, :status_note)
  end

  def down
    remove_column :decidim_bih_reports, :status_note if column_exists?(:decidim_bih_reports, :status_note)
  end
end

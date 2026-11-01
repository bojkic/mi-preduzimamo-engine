# frozen_string_literal: true

# Admin-only triage metadata for citizen reports.
#
# `status_note` is public-facing in the rejection flow, so private operator notes
# live in a separate column. `duplicate_of_report_id` is a lightweight pointer to
# the canonical report when an operator decides two submissions describe the same
# problem; the controller/model enforce same-organization targets.
class AddAdminTriageFieldsToDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    add_internal_note_column
    add_duplicate_pointer_column
    add_duplicate_pointer_index
  end

  private

  def add_internal_note_column
    return if column_exists?(:decidim_bih_reports, :internal_note)

    add_column :decidim_bih_reports, :internal_note, :text
  end

  def add_duplicate_pointer_column
    return if column_exists?(:decidim_bih_reports, :duplicate_of_report_id)

    add_column :decidim_bih_reports, :duplicate_of_report_id, :bigint
  end

  def add_duplicate_pointer_index
    return if index_exists?(
      :decidim_bih_reports,
      [:decidim_organization_id, :duplicate_of_report_id],
      name: "idx_bih_reports_org_duplicate_of"
    )

    add_index :decidim_bih_reports,
              [:decidim_organization_id, :duplicate_of_report_id],
              name: "idx_bih_reports_org_duplicate_of"
  end
end

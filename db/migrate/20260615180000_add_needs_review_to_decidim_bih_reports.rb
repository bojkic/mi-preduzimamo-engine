# frozen_string_literal: true

# Operator "needs review" flag for AI report classifications. When the Gemini
# classifier falls back to its heuristic path (Gemini unconfigured/unavailable/
# parse failure — which always yields category=ostalo/severity=normalan, i.e.
# low confidence), the report is flagged so operators can catch mis-routed or
# unclassified reports instead of them silently sitting as "ostalo".
#
# Defaults false: existing reports are NOT mass-flagged; only newly-processed
# reports get flagged at processing time.
class AddNeedsReviewToDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    add_needs_review_column
    add_needs_review_index
  end

  private

  def add_needs_review_column
    return if column_exists?(:decidim_bih_reports, :needs_review)

    add_column :decidim_bih_reports, :needs_review, :boolean, default: false, null: false
  end

  def add_needs_review_index
    return if index_exists?(
      :decidim_bih_reports,
      [:decidim_organization_id, :needs_review, :created_at],
      name: "idx_bih_reports_org_needs_review_created"
    )

    add_index :decidim_bih_reports,
              [:decidim_organization_id, :needs_review, :created_at],
              name: "idx_bih_reports_org_needs_review_created"
  end
end

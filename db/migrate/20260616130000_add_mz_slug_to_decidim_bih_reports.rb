# frozen_string_literal: true

# Adds a resolved Mjesna zajednica (MZ) slug to citizen reports so the per-MZ
# problem + AI-category heatmap can aggregate reports to a community-level,
# PII-FREE signal (counts by MZ × category × severity × time).
#
# The slug is resolved from the report's coordinates at processing time
# (Decidim::Bih::Geo::PointRouting) and stored as a plain string — NO coordinate
# is carried into the aggregate. Nullable: anonymous/coordinate-less reports and
# points outside every MZ stay nil and are excluded from the heatmap.
#
# The composite [decidim_organization_id, mz_slug] index serves the org-scoped
# GROUP BY mz_slug aggregation.
class AddMzSlugToDecidimBihReports < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_reports, :mz_slug, :string

    add_index :decidim_bih_reports,
              [:decidim_organization_id, :mz_slug],
              name: "idx_bih_reports_org_mz_slug"
  end
end

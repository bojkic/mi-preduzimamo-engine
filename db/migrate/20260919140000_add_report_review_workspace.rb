# frozen_string_literal: true

class AddReportReviewWorkspace < ActiveRecord::Migration[7.2]
  def up
    add_column :decidim_bih_reports, :last_citizen_reply_at, :datetime
    add_column :decidim_bih_reports, :last_reviewed_message_id, :bigint
    add_column :decidim_bih_reports, :review_pending_since, :datetime
    add_column :decidim_bih_reports, :deadline_kind, :string
    add_column :decidim_bih_reports, :review_draft, :jsonb, null: false, default: {}
    add_index :decidim_bih_reports, [:decidim_organization_id, :review_pending_since], name: :idx_bih_reports_review_pending
    execute <<~SQL
      UPDATE decidim_bih_reports r SET
        last_citizen_reply_at = (SELECT MAX(created_at) FROM decidim_bih_report_messages m WHERE m.report_id = r.id AND m.actor_role = 'citizen'),
        last_reviewed_message_id = (SELECT MAX(id) FROM decidim_bih_report_messages m WHERE m.report_id = r.id AND m.actor_role = 'citizen' AND m.created_at <= r.reviewed_at),
        review_pending_since = CASE WHEN review_state = 'pending' AND status NOT IN ('rijeseno','odbijeno') THEN COALESCE((SELECT MAX(created_at) FROM decidim_bih_report_messages m WHERE m.report_id = r.id AND m.actor_role = 'citizen'), r.created_at) END,
        deadline_kind = CASE WHEN review_state = 'needs_information' THEN 'citizen' WHEN status = 'planirano' THEN 'planning' WHEN forwarded_at IS NOT NULL THEN 'city' ELSE 'review' END
    SQL
  end

  def down
    remove_index :decidim_bih_reports, name: :idx_bih_reports_review_pending
    [:last_citizen_reply_at, :last_reviewed_message_id, :review_pending_since, :deadline_kind, :review_draft].each do |column|
      remove_column :decidim_bih_reports, column
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # All-time operational evidence, not model accuracy or active working time.
    # Missing historical human decisions remain explicitly unmeasured.
    class ReportReviewMetrics
      REVIEW_ACTIONS = %w(ask send supplement followup plan reject duplicate resolve external review).freeze

      def initialize(organization:, now: Time.current)
        @organization = organization
        @now = now
      end

      def call
        reports = Report.where(organization: @organization).where(created_at: ..@now)
        proposals = ReportReviewProposal.where(report_id: reports.select(:id)).where(decided_at: ..@now)
        {
          reports: reports.count,
          first_review: elapsed_stats(<<~SQL.squish),
            SELECT id AS report_id, created_at AS received_at, NULL::bigint AS message_id
            FROM decidim_bih_reports WHERE decidim_organization_id = #{organization_id} AND created_at <= #{timestamp}
          SQL
          reply_review: elapsed_stats(<<~SQL.squish),
            SELECT m.report_id, m.created_at AS received_at, m.id AS message_id
            FROM decidim_bih_report_messages m JOIN decidim_bih_reports r ON r.id = m.report_id
            WHERE r.decidim_organization_id = #{organization_id} AND m.actor_role = 'citizen' AND m.kind = 'reply' AND m.created_at <= #{timestamp}
          SQL
          submitted: reports.where.not(forwarded_at: nil).count,
          duplicates: reports.where.not(duplicate_of_report_id: nil).count,
          planned: reports.where(status: "planirano").count,
          overdue: ReportWorkQueue.overdue(base: reports, now: @now).count,
          unknown_delivery: ReportDispatch.where(report_id: reports.select(:id), state: "unknown").distinct.count(:report_id),
          ai_failures_by_reason: ReportReviewProposal.where(report_id: reports.select(:id)).where.not(failure_reason: nil).group(:failure_reason).count,
          ai_repairs: ReportReviewProposal.where(report_id: reports.select(:id), repair_attempted: true).count,
          ai_decisions: proposals.count,
          ai_changed: proposals.where.not(changed_fields: []).count,
          ai_changes_by_action: proposals.where.not(changed_fields: []).group(:approved_action).count
        }
      end

      private

      def organization_id = Report.connection.quote(@organization.id)

      def timestamp = Report.connection.quote(@now)

      def human_reviews_sql
        actions = REVIEW_ACTIONS.map { |action| Report.connection.quote(action) }.join(",")
        <<~SQL.squish
          SELECT e.decidim_bih_report_id AS report_id, e.occurred_at,
                 NULLIF(e.metadata ->> 'reviewed_message_id', '')::bigint AS reviewed_message_id
          FROM decidim_bih_report_events e
          WHERE e.decidim_organization_id = #{organization_id} AND e.source = 'admin' AND e.occurred_at <= #{timestamp}
          AND (
            (e.event_type = 'case_decision_applied' AND e.metadata ->> 'action' IN (#{actions})) OR
            (e.event_type = 'case_reviewed' AND e.metadata ->> 'review_state' IN ('validated','rejected','needs_information')) OR
            (e.event_type = 'case_message_created' AND e.metadata ->> 'kind' = 'question') OR
            (e.event_type = 'case_planning_updated' AND e.metadata ->> 'status' = 'planirano') OR
            e.event_type = 'case_external_submission_recorded'
          )
        SQL
      end

      def elapsed_stats(received_sql)
        row = Report.connection.select_one(<<~SQL.squish)
          WITH human_reviews AS (#{human_reviews_sql}), received AS (#{received_sql})
          SELECT COUNT(*) AS total, COUNT(reviewed.at) AS measured,
                 percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM reviewed.at - received.received_at))
                   FILTER (WHERE reviewed.at IS NOT NULL) AS median_seconds
          FROM received
          LEFT JOIN LATERAL (
            SELECT MIN(h.occurred_at) AS at FROM human_reviews h
            WHERE h.report_id = received.report_id AND h.occurred_at >= received.received_at
              AND (received.message_id IS NULL OR h.reviewed_message_id >= received.message_id
                   OR (h.reviewed_message_id IS NULL AND h.occurred_at > received.received_at))
          ) reviewed ON TRUE
        SQL
        { total: row.fetch("total").to_i, measured: row.fetch("measured").to_i, median_seconds: row["median_seconds"]&.to_f }
      end
    end
  end
end

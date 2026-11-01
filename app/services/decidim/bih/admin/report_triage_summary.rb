# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # PII-free report attention buckets shared by the admin queue and exports.
      class ReportTriageSummary
        BUCKETS = %w(forwarding_failed received_over_sla stale_city_followup pending_review).freeze
        FORWARDING_SLA_DAYS = ReportWorkQueue::REVIEW_DAYS
        PRIORITY_BY_BUCKET = {
          "forwarding_failed" => "high",
          "received_over_sla" => "high",
          "stale_city_followup" => "watch",
          "pending_review" => "high"
        }.freeze
        ACTION_BY_BUCKET = {
          "forwarding_failed" => "retry_forwarding",
          "received_over_sla" => "forward_received_report",
          "stale_city_followup" => "check_city_followup",
          "pending_review" => "review_citizen_reply"
        }.freeze
        ATTENTION_COLUMN_BY_BUCKET = {
          "forwarding_failed" => :forwarding_failed_at,
          "received_over_sla" => :created_at,
          "stale_city_followup" => :created_at,
          "pending_review" => :review_pending_since
        }.freeze

        def initialize(organization:, now: Time.current)
          @organization = organization
          @now = now
        end

        def rows
          [
            summary_row("forwarding_failed", scope_for("forwarding_failed"), :forwarding_failed_at),
            summary_row("received_over_sla", scope_for("received_over_sla"), :created_at),
            summary_row("stale_city_followup", scope_for("stale_city_followup"), :created_at),
            summary_row("pending_review", scope_for("pending_review"), :review_pending_since)
          ]
        end

        def scope_for(bucket, base_scope: report_scope)
          case bucket
          when "forwarding_failed"
            ReportWorkQueue.forwarding_failures(base: base_scope)
          when "received_over_sla"
            ReportWorkQueue.overdue(base: base_scope.where(status: "primljeno", review_state: %w(pending validated)), now:)
          when "stale_city_followup"
            ReportWorkQueue.overdue(base: base_scope.where(status: %w(proslijedjeno u_obradi)).where.not(forwarded_at: nil)
                                                   .where.not(review_state: %w(pending needs_information)), now:)
          when "pending_review"
            base_scope.where(review_state: "pending").where.not(status: Report::TERMINAL_STATUSES)
          else
            base_scope
          end
        end

        def report_rows(bucket: nil, base_scope: report_scope, limit: 20)
          limit = limit.to_i
          return [] unless limit.positive?

          seen_report_ids = {}
          buckets_for(bucket).each_with_object([]) do |bucket_name, rows|
            ordered_scope_for(bucket_name, base_scope:).limit(limit).each do |report|
              next if seen_report_ids[report.id]

              seen_report_ids[report.id] = true
              rows << report_row(bucket_name, report)
              return rows if rows.size >= limit
            end
          end
        end

        private

        attr_reader :organization, :now

        def report_scope
          Decidim::Bih::Report.where(organization:)
        end

        def summary_row(bucket, scope, oldest_attention_column)
          count = scope.count
          oldest_attention_at = scope.minimum(Arel.sql(attention_sql(bucket, fallback: oldest_attention_column)))
          oldest_reported_at = scope.minimum(:created_at)
          latest_reported_at = scope.maximum(:created_at)

          {
            key: bucket,
            bucket:,
            count:,
            review_priority: review_priority(bucket, count),
            review_action: review_action(bucket, count),
            oldest_at: oldest_attention_at,
            oldest_attention_on: date_value(oldest_attention_at),
            oldest_reported_on: date_value(oldest_reported_at),
            latest_reported_on: date_value(latest_reported_at),
            forwarding_sla_days: FORWARDING_SLA_DAYS,
            stale_days: Decidim::Bih::Report::STALE_DAYS
          }
        end

        def date_value(value)
          value&.to_date&.iso8601
        end

        def review_priority(bucket, count)
          return "monitor" if count.to_i.zero?

          PRIORITY_BY_BUCKET.fetch(bucket)
        end

        def review_action(bucket, count)
          return "continue_monitoring" if count.to_i.zero?

          ACTION_BY_BUCKET.fetch(bucket)
        end

        def buckets_for(bucket)
          BUCKETS.include?(bucket) ? [bucket] : BUCKETS
        end

        def ordered_scope_for(bucket, base_scope:)
          scope_for(bucket, base_scope:).reorder(Arel.sql("#{attention_sql(bucket)} ASC NULLS LAST"))
        end

        def attention_sql(bucket, fallback: ATTENTION_COLUMN_BY_BUCKET.fetch(bucket))
          return ReportWorkQueue.deadline_sql if %w(received_over_sla stale_city_followup).include?(bucket)
          return ReportWorkQueue::REVIEW_ANCHOR if bucket == "pending_review"

          fallback.to_s
        end

        def attention_at(bucket, report)
          return ReportWorkQueue.due_at(report) if %w(received_over_sla stale_city_followup).include?(bucket)
          return report.review_pending_since || report.last_citizen_reply_at || report.created_at if bucket == "pending_review"

          report.public_send(ATTENTION_COLUMN_BY_BUCKET.fetch(bucket))
        end

        def report_row(bucket, report)
          {
            reference: report.reference,
            bucket:,
            review_priority: PRIORITY_BY_BUCKET.fetch(bucket),
            review_action: ACTION_BY_BUCKET.fetch(bucket),
            status: ReportStatusPresenter.status_key(report),
            category: report.category,
            severity: report.severity,
            mz_slug: report.mz_slug,
            reported_at: report.created_at,
            attention_at: attention_at(bucket, report)
          }
        end
      end
    end
  end
end

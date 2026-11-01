# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- explicit independent policy and safety guards

module Decidim
  module Bih
    # One definition of operational attention for screens, counters and reminders.
    # The classifier fallback flag is deliberately NOT a human review decision.
    class ReportWorkQueue
      VIEWS = %w(review citizen city planning finished all).freeze
      PAGE_SIZE = 25
      REVIEW_DAYS = 2
      CITIZEN_DAYS = 7
      CITY_DAYS = ReportObligations::DEADLINES.fetch(:city_response)
      REVIEW_ANCHOR = "COALESCE(review_pending_since, last_citizen_reply_at, created_at)"
      CITY_ANCHOR = "forwarded_at"

      def initialize(organization:, now: Time.current)
        @organization = organization
        @now = now
      end

      def scope(view = "review", base: Report.where(organization: @organization))
        active = base.where.not(status: Report::TERMINAL_STATUSES).where(duplicate_of_report_id: nil)
        staff_tasks = ReportObligation.open.where(actor: "staff").select(:report_id)
        city_tasks = ReportObligation.open.where(actor: "city").select(:report_id)
        recorded_city_tasks = ReportObligation.where(kind: %w(city_response city_commitment), actor: "city").select(:report_id)
        citizen_tasks = ReportObligation.open.where(actor: "citizen").select(:report_id)
        case view
        when "review"
          active.where(review_state: %w(pending validated), status: "primljeno").where.not(id: ReportDispatch.where(state: %w(queued sending)).select(:report_id))
                .or(active.where(review_state: "pending"))
                .or(active.where(id: staff_tasks).where.not(status: "planirano"))
                .or(self.class.forwarding_failures(base: active))
                .or(active.where(id: ReportDispatch.where(state: "unknown").select(:report_id)))
                # An expired citizen reply deadline does not create a new review task.
                .or(self.class.overdue(base: active.where.not(review_state: "needs_information"), now: @now))
        when "citizen" then active.where(review_state: "needs_information").or(active.where(id: citizen_tasks))
        when "city" then active.where.not(forwarded_at: nil).where.not(review_state: %w(pending
                                                                                        needs_information)).where.not(id: recorded_city_tasks).or(active.where(id: city_tasks))
        when "planning" then active.where(status: "planirano")
        when "finished" then base.where(status: Report::TERMINAL_STATUSES).or(base.where.not(duplicate_of_report_id: nil))
        else base
        end
      end

      def search(base, query)
        query = query.to_s.strip.first(120)
        return base if query.blank?

        base.full_text_search(query).order(Arel.sql(Report.sanitize_sql_array(
                                                      ["ts_rank(to_tsvector('simple', coalesce(search_text, '')), to_tsquery('simple', ?)) DESC",
                                                       ReportSearchText.tsquery(query)]
                                                    )))
      end

      def ordered(base)
        base.order(Arel.sql("CASE WHEN forwarding_failed_at IS NOT NULL THEN 0 WHEN review_state = 'pending' THEN 1 ELSE 2 END"))
            .order(Arel.sql("#{self.class.deadline_sql} ASC NULLS LAST"), id: :asc)
      end

      def counts
        VIEWS.index_with { |view| scope(view).count }
      end

      def self.forwarding_failures(base: Report.all)
        base.where.not(forwarding_failed_at: nil).where(duplicate_of_report_id: nil)
            .where.not(status: Report::TERMINAL_STATUSES + ["planirano"]).where.not(review_state: "needs_information")
            .where.not(id: ReportDispatch.where(state: %w(queued sending)).select(:report_id))
      end

      def self.overdue(base: Report.all, now: Time.current)
        base.where("(#{deadline_sql}) < ?", now)
      end

      # SQL and presenter share the same deadline precedence. Explicit operator
      # deadlines win; absent legacy deadlines derive from the relevant event,
      # never from an unrelated integration poll or a later page visit.
      def self.deadline_sql
        table = Report.table_name
        sending = "EXISTS (SELECT 1 FROM decidim_bih_report_dispatches d WHERE d.report_id = #{table}.id AND d.state IN ('queued','sending'))"
        <<~SQL.squish
          CASE
            WHEN #{table}.status IN ('rijeseno','odbijeno','zatvoreno') OR #{table}.duplicate_of_report_id IS NOT NULL THEN NULL
            WHEN #{table}.review_state <> 'pending' AND #{sending} THEN NULL
            ELSE #{ReportObligations.deadline_sql(table:)}
          END
        SQL
      end

      def self.sending?(report)
        report.dispatches.any? { |dispatch| %w(queued sending).include?(dispatch.state) }
      end

      def self.due_at(report)
        return if closed?(report)
        return if report.review_state != "pending" && sending?(report)

        ReportObligations.next_action(report)&.due_at
      end

      def self.derived_due_at(report)
        return (report.review_pending_since || report.last_citizen_reply_at || report.created_at) + REVIEW_DAYS.days.to_i if report.review_state == "pending"
        return report.case_messages.where(kind: "question").maximum(:created_at)&.+(CITIZEN_DAYS.days.to_i) if report.review_state == "needs_information"

        post_review_due_at(report)
      end

      def self.post_review_due_at(report)
        return report.report_collection&.review_due_at if report.planned?
        return report.forwarded_at + CITY_DAYS.days.to_i if report.forwarded_at

        (report.reviewed_at || report.created_at) + REVIEW_DAYS.days.to_i if report.status == "primljeno" && report.review_state == "validated"
      end

      def self.closed?(report)
        Report::TERMINAL_STATUSES.include?(report.status) || report.duplicate?
      end

      def self.waiting_on(report)
        return "finished" if closed?(report)
        return "review" if report.review_state == "pending"
        return "review" if report.dispatches.any? { |dispatch| dispatch.state == "unknown" }
        return "sending" if sending?(report)
        return "review" if report.obligations.open.exists?(kind: %w(delivery_exception dispatch_approval evidence_handoff dispute_review))

        task = ReportObligations.next_action(report)
        return "review" if task&.actor == "staff" && !report.planned?
        return "citizen" if task&.actor == "citizen"
        return "city" if task&.actor == "city"
        return "citizen" if report.review_state == "needs_information"
        return "planning" if report.planned?
        return "city" if report.forwarded_at

        "review"
      end
    end
  end
end

# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

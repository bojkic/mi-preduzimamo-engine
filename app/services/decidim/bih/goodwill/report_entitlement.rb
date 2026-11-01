# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      # A source remains evidence of a consumed entitlement even after correction.
      # This prevents changing a duplicate link, reversing an earn, or switching
      # between the report and corroboration paths from purchasing another slot.
      module ReportEntitlement
        DUPLICATE_POINTS = 5
        module_function

        def effective_at(organization)
          value = Setting.namespace_for(organization, EarningRules::POLICY_NAMESPACE)["report_problem_effective_at"]
          value.present? ? Time.iso8601(value) : Time.at(0).utc
        end

        def root(report)
          seen = []
          current = report
          while current.duplicate_of_report_id.present?
            raise ArgumentError, "cyclic report duplicates" if seen.include?(current.id)
            seen << current.id
            current = Report.find_by!(organization: report.organization, id: current.duplicate_of_report_id)
          end
          current
        end

        def family_ids(report)
          ids = [root(report).id]
          loop do
            children = Report.where(organization: report.organization, duplicate_of_report_id: ids).pluck(:id)
            expanded = (ids + children).uniq
            break if expanded == ids
            ids = expanded
          end
          ids
        end

        def outcome_target(report)
          ordinary_points = EarningRules.points_for_action(:report, organization: report.organization)
          return 0 unless ordinary_points.positive?
          last_action = report.events.where(event_type: "case_decision_applied").order(id: :desc).pick(Arel.sql("metadata->>'action'"))
          if report.status == "odbijeno" && (last_action == "reject" || report.duplicate_of_report_id.blank?)
            # Owner decision 2026-10-05: race reports closed only because the
            # citizen did not answer keep their points; afterwards they lose them.
            return no_reply_closure_during_race?(report) ? ordinary_points : 0
          end
          return ordinary_points if report.duplicate_of_report_id.blank?
          # A duplicate remains a five-point submitted report unless THIS
          # report was explicitly rejected; its parent outcome is not a penalty.
          DUPLICATE_POINTS
        end

        def no_reply_closure_during_race?(report)
          report.closure_basis == "bez_odgovora" && report.duplicate_of_report_id.blank? &&
            report.created_at < Race::Config.new(organization: report.organization).window_to
        end

        def target(report, account:, source_key:, occurred_at:)
          amount = outcome_target(report)
          return amount if occurred_at < effective_at(report.organization)
          return 0 if amount.zero?
          available?(report, account:, source_key:, occurred_at:) ? amount : 0
        end

        def available?(report, account:, source_key:, occurred_at:)
          ids = family_ids(report)
          corroborations = ReportCorroboration.where(organization: report.organization)
            .where("report_id IN (:ids) OR original_report_id IN (:ids)", ids:).pluck(:id)
          keys = ids.map { |id| IdempotencyKey.report(id) } + corroborations.map { |id| "report-corroboration:#{id}" }
          sources = Transaction.where(organization: report.organization, kind: "earn", idempotency_key: keys)
            .joins(:entries).where(decidim_bih_goodwill_entries: { decidim_bih_goodwill_account_id: account.id })
            .where("decidim_bih_goodwill_entries.amount > 0").distinct.to_a
          candidates = sources.map { |source| [SourceCreditCorrection.earning_time(source), source.idempotency_key] }
          candidates << [occurred_at, source_key]
          candidates.min_by { |time, key| [time, key] }.last == source_key
        end
      end
    end
  end
end

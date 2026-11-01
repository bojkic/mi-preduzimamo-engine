# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      class CorroborateReport
        Result = Struct.new(:report, :corroboration, :transaction, :outcome, keyword_init: true)

        def self.call(report:, user:)
          root = ReportEntitlement.root(report)
          # Historical anonymous clicks remain only a public non-binding count.
          unless user
            Report.increment_counter(:corroboration_count, root.id)
            return Result.new(report: root, outcome: "unregistered")
          end
          raise ArgumentError, "ineligible corroboration actor" unless user.organization == report.organization &&
            !user.deleted? && !user.blocked? && !user.group?

          account = Ledger.new.account_for(user)
          AccountLocks.with(account) do
            root = ReportEntitlement.root(report.reload)
            root.lock!
            family = ReportEntitlement.family_ids(root)
            existing = ReportCorroboration.where(organization: report.organization, user:)
              .where("report_id IN (:ids) OR original_report_id IN (:ids)", ids: family).order(:id).first
            next Result.new(report: root, corroboration: existing, outcome: "replayed") if existing

            record = ReportCorroboration.create!(organization: report.organization, user:, report: root, original_report: report)
            Report.increment_counter(:corroboration_count, root.id)
            transaction = EarningRules.new(organization: report.organization).award(user, :report,
              idempotency_key: "report-corroboration:#{record.id}", metadata: { corroboration_id: record.id, occurred_at: record.created_at.iso8601 })
            admission = AwardAdmission.find_by!(organization: report.organization, source_key: "report-corroboration:#{record.id}")
            Result.new(report: root, corroboration: record, transaction:, outcome: transaction ? "corroborated" : admission.outcome)
          end
        end
      end
    end
  end
end

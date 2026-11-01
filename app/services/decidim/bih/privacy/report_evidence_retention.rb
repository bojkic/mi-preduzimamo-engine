# frozen_string_literal: true

module Decidim
  module Bih
    module Privacy
      class ReportEvidenceRetention
        def initialize(organization:, cutoff:, dry_run: true)
          @organization = organization
          @cutoff = cutoff
          @dry_run = dry_run
        end

        def call(bucket: :report_evidence_shares)
          raise ArgumentError, "Unknown evidence retention bucket" unless bucket == :report_evidence_shares
          return 0 unless @cutoff

          scope = ReportEvidenceItem.joins(:report).where(decidim_bih_reports: { decidim_organization_id: @organization.id, status: Report::TERMINAL_STATUSES })
                                    .where("decidim_bih_report_evidence_items.updated_at < ?", @cutoff).where(purged_at: nil)
          # Recover the commit-before-enqueue crash window from durable tombstones.
          unless @dry_run
            ReportEvidenceItem.joins(:report).where(decidim_bih_reports: { decidim_organization_id: @organization.id })
                              .where.not(purged_at: nil).find_each(&:enqueue_purge)
          end
          count = 0
          scope.find_each do |item|
            report = item.report
            report.with_lock do
              next unless eligible_report?(report.reload)

              count += 1
              item.ensure_private!.tombstone! unless @dry_run
            end
          end
          count
        end

        private

        def eligible_report?(report)
          Report::TERMINAL_STATUSES.include?(report.status) && report.updated_at < @cutoff &&
            !report.dispatches.exists?(state: %w(queued sending unknown)) && linked_reports_eligible?(report)
        end

        def linked_reports_eligible?(report)
          return true unless defined?(InboundEmailLink) && InboundEmailLink.table_exists?

          linked_mails = InboundEmailLink.where(report:).select(:inbound_email_id)
          linked_reports = Report.where(id: InboundEmailLink.where(inbound_email_id: linked_mails).select(:report_id))
          !linked_reports.where.not(status: Report::TERMINAL_STATUSES).exists? && !linked_reports.exists?(updated_at: @cutoff..)
        end
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    module Privacy
      class ReportMailRetention
        def initialize(organization:, cutoff:, dry_run: true)
          @organization, @cutoff, @dry_run = organization, cutoff, dry_run
        end
        def call(unlinked: false)
          return 0 unless @cutoff
          count = 0
          InboundEmail.where(organization: @organization, data_redacted_at: nil).where(updated_at: ...@cutoff).find_each do |email|
            email.with_lock do
              reports = email.reports.order(:id).to_a
              next unless reports.empty? == unlinked
              # Keep all material while even one linked report is live, recently
              # touched, or has an unresolved delivery requiring reconciliation.
              next unless reports.all? { |report| %w(rijeseno zatvoreno odbijeno).include?(report.status) && report.updated_at < @cutoff && !report.dispatches.where(state: %w(queued sending unknown)).exists? }
              next if %w(stored processing).include?(email.state)
              unless @dry_run
                email.attachments.each do |attachment|
                  retained_by_evidence = defined?(ReportEvidenceItem) && ReportEvidenceItem.table_exists? && ReportEvidenceItem.exists?(blob_id: attachment.blob_id)
                  attachment.purge unless retained_by_evidence
                end
                email.update_columns(raw_ciphertext: nil, subject_ciphertext: nil, body_text_ciphertext: nil, data_redacted_at: Time.current)
              end
              count += 1
            end
          end
          count
        end
      end
    end
  end
end

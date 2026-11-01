# frozen_string_literal: true

module Decidim
  module Bih
    module Privacy
      # Content-only lifecycle for private review copies. The caller supplies
      # the approved cutoff; this service never invents a retention period.
      class ReportReviewRetention
        FINISHED_DISPATCH_STATES = %w(accepted cancelled not_sent).freeze

        def initialize(organization:, cutoff:, dry_run: true)
          @organization = organization
          @cutoff = cutoff
          @dry_run = dry_run
        end

        def call(bucket: nil)
          return bucket ? empty_counts.fetch(bucket) : empty_counts unless cutoff

          operations = { report_dispatch_contents: [dispatches, :redact_dispatch],
                         report_review_proposals: [proposals, :redact_proposal],
                         report_review_drafts: [drafts, :redact_draft] }
          return process(*operations.fetch(bucket)) if bucket

          operations.transform_values { |scope, action| process(scope, action) }
        end

        private

        attr_reader :organization, :cutoff, :dry_run

        def empty_counts
          { report_dispatch_contents: 0, report_review_proposals: 0, report_review_drafts: 0 }
        end

        def report_scope = Report.where(organization:)

        def dispatches
          ReportDispatch.where(report_id: report_scope.select(:id), state: FINISHED_DISPATCH_STATES, data_redacted_at: nil)
                        .where(updated_at: ...cutoff)
        end

        def proposals
          ReportReviewProposal.where(report_id: report_scope.select(:id), data_redacted_at: nil).where(updated_at: ...cutoff)
        end

        # Using report.updated_at is conservative: any more recent case work
        # preserves its draft, even if the draft itself was saved earlier.
        def drafts
          report_scope.where(updated_at: ...cutoff).where.not(review_draft: {})
        end

        def process(scope, action)
          return scope.count if dry_run

          count = 0
          scope.find_each do |record|
            report = record.is_a?(Report) ? record : record.report
            report.with_lock do
              # Recheck after acquiring the same report lock used by decisions,
              # AI generation and dispatch claims; stale scope rows are skipped.
              next unless scope.exists?(record.id)

              record.reload
              send(action, record)
              count += 1
            end
          end
          count
        end

        def redact_dispatch(dispatch)
          marker = Infobip::EncryptedJobEnvelope.seal({ retention_redacted: true }, purpose: "report-dispatch", salt: "bih-report-dispatch-v1")
          # Privacy is the sole exception to immutable content. Preserve original
          # approval/outcome times and deduplication metadata, never resend it.
          dispatch.update_columns(snapshot_ciphertext: marker, reconciliation_evidence: nil, data_redacted_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        end

        def redact_proposal(proposal)
          proposal.update_columns(proposal_ciphertext: nil, state: "unavailable", error_code: "retention_redacted", data_redacted_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        end

        def redact_draft(report)
          report.update_columns(review_draft: {}) # rubocop:disable Rails/SkipsModelValidations
        end
      end
    end
  end
end

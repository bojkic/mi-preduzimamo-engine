# frozen_string_literal: true

module Decidim
  module Bih
    # Background-side processor for a persisted citizen report. Location
    # enrichment is best effort; forwarding only flips the report to
    # "proslijedjeno" after the Sistem 48 forwarder accepts the payload.
    class ReportProcessing
      class ForwardingFailed < StandardError
        attr_reader :code

        def initialize(message = "Sistem48 forwarding failed", code: "sistem48_forwarding_failed")
          @code = code
          super(message)
        end
      end

      def initialize(forwarder: Decidim::Bih::Sistem48::Forwarder.new)
        @forwarder = forwarder
      end

      # Legacy unattended intake honors the explicit host switch. Manual
      # approvals use ReportDecision/ReportDispatching; forward: true is not
      # an approval and cannot override a review-first host.
      def call(report:, locale: "sr", forward: auto_forward?, reviewed: false) # rubocop:disable Lint/UnusedMethodArgument -- preserve existing intake job API
        Decidim::Bih::Instrumentation.instrument(
          "report_processing",
          report_id: report.id,
          organization_id: report.decidim_organization_id,
          reference: report.reference
        ) do |event|
          enrich_location(report)
          if forward && auto_forward? && !reviewed && !self.class.review_first?(report.organization)
            forward(report.reload, reviewed:)
          else
            hold_for_review(report.reload)
          end
          ReportReviewAssistant.enqueue(report)
          event[:status] = report.reload.status

          report
        end
      end

      def self.review_first?(organization)
        settings = Setting.namespace_for(organization, "reports")
        value = settings.fetch("review_first", Decidim::Bih.report_review_first)
        # A missing/null/empty value must not opt a host out of staff review.
        ActiveModel::Type::Boolean.new.cast(value) != false
      end

      def auto_forward?
        return true unless Decidim::Bih.respond_to?(:sistem48_auto_forward)

        Decidim::Bih.sistem48_auto_forward != false
      end

      private

      attr_reader :forwarder

      def enrich_location(report)
        report.with_lock { report.update!(mz_slug: resolve_mz_slug(report)) if report.mz_slug.blank? }
      rescue StandardError => e
        Rails.logger.warn("[ReportProcessing] location enrichment failed report=#{report.id} error=#{e.class}")
        nil
      end

      # Resolve a located report to its Mjesna zajednica slug for the heatmap.
      # Returns nil when either coordinate is missing or any lookup error occurs
      # (best-effort enrichment must never break processing/forwarding).
      def resolve_mz_slug(report)
        return nil if report.latitude.blank? || report.longitude.blank?

        Decidim::Bih::Geo::PointRouting.resolve(
          lat: report.latitude,
          lon: report.longitude,
          organization: report.organization
        )[:mz_slug]
      rescue StandardError
        nil
      end

      # Review-first: leave the report "primljeno" and say so in its event
      # trail, once, so the operator queue (which lists stuck primljeno reports
      # first) and the review page both explain why nothing was sent.
      def hold_for_review(report)
        return unless report.status == "primljeno"
        return if report.forwarded_at.present?

        report.record_event!(
          "forwarding_held_for_review",
          source: "background",
          actor_role: "system",
          metadata: { status: report.status }
        )
      end

      def forward(report, reviewed: false)
        # Serialize the read-decide-write on the report row. Sidekiq's at-least
        # -once delivery can run two overlapping attempts for the same report;
        # without the lock both pass the forwarded_at.nil? gate and BOTH email
        # the city. with_lock reloads under FOR UPDATE so exactly one attempt
        # observes the not-yet-forwarded state, sends, and persists. The forward
        # outcome is captured and any failure recorded AFTER the lock commits, so
        # the failure metadata is never rolled back by the raised exception.
        # forwarding_error is recorded + raised; an already-typed ForwardingFailed
        # from the forwarder is re-raised verbatim without a second recording,
        # matching the prior `rescue ForwardingFailed; raise` semantics.
        forwarding_error = nil
        reraise = nil

        report.with_lock do
          forwarding_error = attempt_forward(report, reviewed:)
        rescue ForwardingFailed => e
          reraise = e
        rescue StandardError => e
          forwarding_error = e
        end

        raise reraise if reraise

        raise_forwarding_failure(report, forwarding_error) if forwarding_error
      end

      # Runs the gate + send while the caller holds the report row lock. Returns
      # the forwarding error to record (nil on success/no-op). Must not record or
      # raise — the caller does that after the lock's transaction commits so the
      # failure metadata survives.
      def ready_to_forward?(report, reviewed:)
        # This legacy transport remains only for hosts explicitly configured for
        # unattended intake forwarding. It is never a manual approval path.
        return false if reviewed || !auto_forward? || self.class.review_first?(report.organization)
        return false if human_review_started?(report)
        return false if report.planned? || report.collective? || report.duplicate?

        report.status == "primljeno"
      end

      def human_review_started?(report)
        report.dispatches.exists? || report.reviewed_at.present? || report.review_draft.present? || report.review_state != "pending"
      end

      def attempt_forward(report, reviewed: false)
        return unless ready_to_forward?(report, reviewed:)

        # A prior attempt already emailed the city (forwarded_at recorded) but
        # crashed before persisting the status. Reconcile the status WITHOUT
        # re-sending — re-emailing the city on every retry is the real harm.
        if report.forwarded_at.present?
          report.update!(status: "proslijedjeno")
          report.record_event!(
            "forwarding_reconciled",
            source: "background",
            actor_role: "system",
            metadata: {
              status: report.status,
              forwarded_at: report.forwarded_at
            }
          )
          report.clear_forwarding_failure!(reason: "forwarding_reconciled", source: "background") if report.forwarding_failed_at?
          return
        end

        return forwarder_failure || ForwardingFailed.new unless forwarder.call(report.to_forwarder_hash)

        # Record the irreversible "email sent" fact first, in a minimal single
        # -column write (no validations/callbacks), so a failure of the status
        # update below cannot trigger a duplicate send on retry.
        report.update_column(:forwarded_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
        report.update!(status: "proslijedjeno")
        report.record_event!(
          "forwarding_sent",
          source: "background",
          actor_role: "system",
          metadata: {
            status: report.status,
            forwarded_at: report.forwarded_at
          }
        )
        report.clear_forwarding_failure!(reason: "forwarding_sent", source: "background") if report.forwarding_failed_at?
        nil
      end

      def forwarder_failure
        return unless forwarder.respond_to?(:last_error)

        forwarder.last_error
      end

      def raise_forwarding_failure(report, error)
        code = Decidim::Bih::SafeErrorMetadata.error_code(error, explicit: error_code(error)) ||
               "sistem48_forwarding_failed"
        report.record_forwarding_failure!(error, code: code, source: "background")

        raise ForwardingFailed.new(report.forwarding_error_message, code: code)
      end

      def error_code(error)
        error.respond_to?(:code) ? error.code : nil
      end
    end
  end
end

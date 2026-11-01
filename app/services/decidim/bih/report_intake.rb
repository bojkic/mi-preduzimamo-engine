# frozen_string_literal: true

require_relative "durable_effects"

module Decidim
  module Bih
    # Intake service for the "Bice riseno" civic reporting feature: it persists
    # a citizen Report and enqueues the slower AI enrichment / Sistem 48
    # forwarding work. Persistence stays first so the citizen submission is not
    # lost if any downstream integration is slow or unavailable.
    #
    #   Decidim::Bih::ReportIntake.new.call(
    #     organization: org, description: "Rupa na putu", address: "..."
    #   ) # => persisted Decidim::Bih::Report
    #
    class ReportIntake
      def initialize(processing_job: Decidim::Bih::ReportProcessingJob)
        @processing_job = processing_job
      end

      # rubocop:disable Metrics/ParameterLists
      def call(organization:, description:, address: nil, latitude: nil, longitude: nil,
               reporter_email: nil, reporter_phone: nil, anonymous: false, photo: nil,
               public_location_exact: false, locale: "sr", author: nil)
        report = Decidim::Bih::Report.new(
          organization: organization,
          author: (author if author.is_a?(Decidim::User)),
          description: description,
          address: address,
          latitude: latitude,
          longitude: longitude,
          reporter_email: reporter_email,
          reporter_phone: reporter_phone,
          anonymous: anonymous,
          public_location_exact: public_location_exact,
          status: "primljeno"
        )
        normalized_photo = Decidim::Bih::Media::ImageNormalizer.call(photo) if photo
        report.photo.attach(normalized_photo) if normalized_photo

        # Persist FIRST so the submission is never lost, regardless of what the
        # classifier/forwarder does later. Enrichment, forwarding and the
        # recognition award are all best-effort.
        save_with_reference_retry(report)
        report.record_event!(
          "report_created",
          actor: author,
          source: "public",
          actor_role: author.is_a?(Decidim::User) ? "citizen" : "public",
          metadata: {
            anonymous: anonymous,
            has_photo: report.photo.attached?,
            has_location: latitude.present? && longitude.present?,
            public_location_exact: ActiveModel::Type::Boolean.new.cast(public_location_exact),
            has_contact: reporter_email.present? || reporter_phone.present?
          }
        )
        @submitted_report = report
        @awarded_points = award_contribution(report, author)
        enqueue_staff_alert(report)
        enqueue_processing(report, locale)

        report
      end
      # rubocop:enable Metrics/ParameterLists

      # Returns the number of goodwill points awarded for the most recent #call,
      # or nil when nothing was awarded (signed-out report, cap reached, etc.).
      # Callers (e.g. the web controller) use this to surface "+N bodova" inline.
      def awarded_points
        return @awarded_points.credited_amount if @awarded_points.respond_to?(:credited_amount)
        transaction = goodwill_transaction
        transaction && Goodwill::SourceCreditCorrection.recognized_total(transaction)
      rescue StandardError
        nil
      end

      def award_outcome
        return "unregistered" unless @submitted_report&.author
        return "ordinary" if awarded_points.to_i.positive?
        admission = Goodwill::AwardAdmission.find_by(organization: @submitted_report.organization,
          source_key: Goodwill::IdempotencyKey.report(@submitted_report.id))
        admission&.outcome || "pending"
      rescue StandardError
        "pending"
      end

      def goodwill_transaction
        return unless @submitted_report
        Goodwill::Transaction.find_by(organization: @submitted_report.organization, kind: "earn",
          idempotency_key: Goodwill::IdempotencyKey.report(@submitted_report.id))
      end

      private

      attr_reader :processing_job

      # Reward a LOGGED-IN reporter with goodwill recognition (report:20), once
      # per report. Signed-out/Viber reports (author nil) earn nothing. The award
      # is idempotent (keyed on the report) so an intake retry never double-pays,
      # and any failure is swallowed so a recognition hiccup can never lose or
      # 500 the report itself. EarningRules also enforces the per-day report cap
      # and skips groups, so this stays a thin, safe call.
      #
      # Returns the Transaction (or nil) so callers can surface the awarded amount.
      def award_contribution(report, author)
        return nil unless author.is_a?(Decidim::User)

        Decidim::Bih::Goodwill::AwardDispatch.report_created(report, author:)
      rescue StandardError => e
        Rails.logger.error(
          "[ReportIntake] goodwill award failed for report #{report.id}: #{e.class}: #{e.message}"
        )
        nil
      end

      # The per-org reference is computed from the current max, so two concurrent
      # intakes can pick the same one; the composite unique index rejects the
      # loser. Retry a few times, regenerating the reference, before giving up.
      def save_with_reference_retry(report, attempts: 3)
        report.save!
      rescue ActiveRecord::RecordNotUnique
        attempts -= 1
        raise if attempts <= 0

        report.reference = nil
        retry
      rescue ActiveRecord::RecordInvalid
        # A rejected photo (too large / wrong type / re-identified content) must
        # never lose the whole submission — drop it and file the report photo-less.
        raise unless report.photo.attached? && report.errors.include?(:photo)

        Rails.logger.warn("[ReportIntake] dropping invalid photo; filing report without it")
        report.photo.detach
        retry
      end

      def enqueue_staff_alert(report)
        Decidim::Bih::DurableEffects.enqueue(Decidim::Bih::ReportStaffAlertJob, report.id)
      rescue StandardError => e
        Rails.logger.error("[ReportIntake] staff alert enqueue failed for report #{report.id}: #{e.class}")
      end

      def enqueue_processing(report, locale)
        Decidim::Bih::DurableEffects.enqueue(processing_job, report.id, locale: locale)
        report.record_event!(
          "processing_enqueued",
          source: "background",
          actor_role: "system",
          metadata: { locale: locale }
        )
      rescue StandardError => e
        Rails.logger.error(
          "[ReportIntake] processing enqueue failed for report #{report.id}: #{e.class}: #{e.message}"
        )
        nil
      end
    end
  end
end

# frozen_string_literal: true

module Decidim
  module Bih
    # Runs report classification and Sistem 48 forwarding outside the public
    # request cycle. The report id is passed instead of a GlobalID so a deleted
    # report simply becomes a no-op.
    class ReportProcessingJob < ActiveJob::Base
      queue_as :reports

      retry_on Decidim::Bih::ReportProcessing::ForwardingFailed,
               wait: :polynomially_longer,
               attempts: 6 do |job, error|
        report_id = job.arguments.first
        safe_message = Decidim::Bih::SafeErrorMetadata.error_message(error)

        Rails.logger.error(
          "[ReportProcessingJob] forwarding exhausted for report #{report_id}: " \
          "#{error.class}: #{safe_message}"
        )
      end

      discard_on ActiveJob::DeserializationError, ActiveRecord::RecordNotFound

      # Retains serialized legacy arguments, but ReportProcessing no longer
      # permits forward: true to override a review-first host's approval flow.
      def perform(report_id, locale: "sr", forward: nil)
        report = Decidim::Bih::Report.find_by(id: report_id)
        return if report.blank?

        options = { report: report, locale: locale }
        options[:forward] = forward unless forward.nil?
        Decidim::Bih::ReportProcessing.new.call(**options)
      end
    end
  end
end

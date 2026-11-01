# frozen_string_literal: true

module Decidim
  module Bih
    # R3 records bounded assessments and fresh shadow proposals. Service-request
    # fulfilment and handoff effects ship in R6, after the lifecycle cutover.
    class ReportEvidenceAssessmentJob < ApplicationJob
      queue_as :reports
      def perform(report_id)
        report = Report.find_by(id: report_id)
        return unless report && !ReportWorkQueue.closed?(report)

        ReportEvidenceItem.sync!(report).each do |item|
          next if item.assessment["format"] == Ai::EvidenceAssessment::FORMAT
          Ai::EvidenceAssessment.new.call(item)
        end
        ReportReviewAssistant.enqueue(report)
      end
    end
  end
end

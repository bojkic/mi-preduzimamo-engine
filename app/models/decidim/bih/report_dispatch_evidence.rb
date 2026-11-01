# frozen_string_literal: true

module Decidim
  module Bih
    class ReportDispatchEvidence < Decidim::ApplicationRecord
      self.table_name = 'decidim_bih_report_dispatch_evidence'
      belongs_to :dispatch, class_name: 'Decidim::Bih::ReportDispatch'
      belongs_to :evidence_item, class_name: 'Decidim::Bih::ReportEvidenceItem'
      belongs_to :request_source, polymorphic: true, optional: true
      validate { errors.add(:evidence_item, :invalid) unless dispatch&.report_id == evidence_item&.report_id }
      def self.sent_for_request?(item, request)
        where(evidence_item: item, request_source: request).joins(:dispatch).where(decidim_bih_report_dispatches: { state: %w(queued sending accepted unknown) }).exists?
      end
    end
  end
end

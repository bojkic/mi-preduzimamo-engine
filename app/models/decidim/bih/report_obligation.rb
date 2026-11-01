# frozen_string_literal: true
module Decidim
  module Bih
    class ReportObligation < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_obligations"
      KINDS = %w(review dispatch_approval closure_approval info_request evidence_collection evidence_handoff city_response city_commitment mail_review dispute_review delivery_exception).freeze
      ACTORS = %w(staff citizen city system).freeze
      STATES = %w(open fulfilled superseded cancelled).freeze
      belongs_to :report, class_name: "Decidim::Bih::Report"
      belongs_to :source, polymorphic: true, optional: true
      belongs_to :fulfilled_by, polymorphic: true, optional: true
      validates :kind, inclusion: { in: KINDS }
      validates :actor, inclusion: { in: ACTORS }
      validates :state, inclusion: { in: STATES }
      validates :effect_key, uniqueness: true, allow_nil: true
      validate :source_in_case
      scope :open, -> { where(state: "open") }
      def self.available? = connection.data_source_exists?(table_name)
      def open? = state == "open"
      private
      def source_in_case
        [source, fulfilled_by].compact.each do |object|
          organization_id = object.respond_to?(:decidim_organization_id) ? object.decidim_organization_id : object.try(:report)&.decidim_organization_id
          errors.add(:source, :invalid) if organization_id && organization_id != report.decidim_organization_id
          errors.add(:source, :invalid) if object.respond_to?(:report_id) && object.report_id && object.report_id != report.id
        end
      end
    end
  end
end

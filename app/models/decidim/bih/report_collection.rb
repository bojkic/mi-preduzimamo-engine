# frozen_string_literal: true

module Decidim
  module Bih
    class ReportCollection < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_collections"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :assigned_to, class_name: "Decidim::User", optional: true
      has_many :reports, class_name: "Decidim::Bih::Report", dependent: :restrict_with_exception
      validates :title, :topic, presence: true, length: { maximum: 200 }
      validates :state, inclusion: { in: %w(collecting ready submitted closed) }
      validates :summary, length: { maximum: 10_000 }
      validates :external_reference, length: { maximum: 240 }
      validate :owner_in_organization

      def draft? = %w(collecting ready).include?(state)

      # Only operator-reviewed summaries, never identities or private conversations.
      def submission_text
        ([title, topic, summary] + reports.order(:reference).map do |report|
          [report.reference, report.report_subtype, report.address, coordinates(report), report.forwarding_note].compact_blank.join("\n")
        end).compact_blank.join("\n\n")
      end

      private

      def coordinates(report)
        return unless report.latitude && report.longitude

        points = ["#{report.latitude}, #{report.longitude}"]
        points << "#{report.location_end_latitude}, #{report.location_end_longitude}" if report.location_end_latitude && report.location_end_longitude
        "GPS: #{points.join(" → ")}"
      end

      def owner_in_organization
        errors.add(:assigned_to, :invalid) if assigned_to && assigned_to.organization != organization
      end
    end
  end
end

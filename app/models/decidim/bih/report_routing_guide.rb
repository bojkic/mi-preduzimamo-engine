# frozen_string_literal: true

module Decidim
  module Bih
    class ReportRoutingGuide < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_routing_guides"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :approved_by, class_name: "Decidim::User", optional: true
      validates :key, :title, :body_sr, presence: true
      validates :key, uniqueness: { scope: :decidim_organization_id }
      validate :reviewed_recipients
      before_update { self.version += 1 if (changed - %w(updated_at version)).any? }
      after_commit :reconsider_reports, on: [:create, :update]
      scope :reviewed, -> { where(active: true).where.not(approved_by_id: nil) }
      def self.recipient_keys(organization)
        ReportTaxonomy::CATEGORIES.map(&:to_s).select { |key| Sistem48::DepartmentRouting.email_for(key, organization).present? }
      end

      private

      def reviewed_recipients
        errors.add(:approved_recipient_keys, :invalid) unless (approved_recipient_keys - self.class.recipient_keys(organization)).empty?
        errors.add(:categories, :invalid) unless (categories - ReportTaxonomy::CATEGORIES.map(&:to_s)).empty?
        errors.add(:approved_by, :invalid) if active && (!approved_by || approved_by.organization != organization)
      end

      def reconsider_reports
        keys = (categories + Array(categories_before_last_save)).uniq
        Report.where(organization:, category: keys).where.not(status: Report::TERMINAL_STATUSES).find_each { |report| ReportReviewAssistant.enqueue(report) }
      end
    end
  end
end

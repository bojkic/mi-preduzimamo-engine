# frozen_string_literal: true
module Decidim
  module Bih
    class ReportCorroboration < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_corroborations"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
      belongs_to :report, class_name: "Decidim::Bih::Report"
      belongs_to :original_report, class_name: "Decidim::Bih::Report"
      validate :same_organization
      validates :decidim_user_id, uniqueness: { scope: [:decidim_organization_id, :report_id] }
      private
      def same_organization
        errors.add(:base, :invalid) unless [user, report, original_report].all? { |record| record && record.organization == organization }
      end
    end
  end
end

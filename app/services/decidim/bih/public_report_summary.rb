# frozen_string_literal: true

module Decidim
  module Bih
    # Privacy-safe aggregate counts for public report surfaces.
    #
    # This deliberately returns counts only: no descriptions, reporter contact,
    # status tokens, photos, coordinates, or per-person details.
    class PublicReportSummary
      RECENT_WINDOW = 7.days

      def initialize(organization)
        @organization = organization
      end

      def call
        {
          total: scope.count,
          open: open_count,
          resolved: status_counts["rijeseno"].to_i,
          recent: scope.where(created_at: RECENT_WINDOW.ago..).count,
          located: located_scope.count,
          mapped_mz: scope.where.not(mz_slug: [nil, ""]).count,
          status_counts:
        }
      end

      private

      attr_reader :organization

      def scope
        @scope ||= Decidim::Bih::Report.publicly_visible.where(organization:)
      end

      def located_scope
        scope.where.not(latitude: nil).where.not(longitude: nil)
      end

      def status_counts
        @status_counts ||= ReportStatusPresenter.status_counts(scope)
      end

      def open_count
        status_counts.except(*Decidim::Bih::Report::TERMINAL_STATUSES, "duplicate").values.sum
      end
    end
  end
end

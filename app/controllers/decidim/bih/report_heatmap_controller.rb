# frozen_string_literal: true

module Decidim
  module Bih
    # Public, anonymous per-Mjesna zajednica (MZ) problem heatmap. Turns the
    # individual citizen reports into a community-level signal: "ovog mjeseca:
    # 40% putevi u MZ Centar". Like ReportsMapController it inherits from
    # Decidim::ApplicationController so it gets current_organization (from the
    # request host) and the Decidim layout without an authenticated user.
    #
    # PII-SAFE: it only ever renders the ReportHeatmap aggregate (counts by
    # MZ × category × severity × time) — never descriptions, contacts,
    # coordinates or references.
    #
    # GET /biceriseno/mapa-problema  -> per-MZ, per-category counts table
    class ReportHeatmapController < Decidim::ApplicationController
      # Allowlisted time windows (days) the public can switch between via ?days=.
      ALLOWED_WINDOWS = [30, 90, 365].freeze
      DEFAULT_WINDOW = 90

      def index
        @window_days = window_days
        @heatmap = Decidim::Bih::ReportHeatmap.new(
          organization: current_organization,
          since: @window_days.days.ago
        ).call
        @report_summary = Decidim::Bih::PublicReportSummary.new(current_organization).call
      end

      private

      def window_days
        requested = params[:days].to_i
        ALLOWED_WINDOWS.include?(requested) ? requested : DEFAULT_WINDOW
      end
    end
  end
end

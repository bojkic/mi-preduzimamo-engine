# frozen_string_literal: true

module Decidim
  module Bih
    # Public, anonymous map of located citizen problem reports ("Bice riseno!").
    # Like ReportsController it inherits from Decidim::ApplicationController so it
    # gets current_organization (from the request host) and the Decidim layout
    # without requiring an authenticated user.
    #
    # GET /biceriseno/mapa        -> Leaflet map page (HTML)
    # GET /biceriseno/mapa.json   -> GeoJSON FeatureCollection of located reports
    class ReportsMapController < Decidim::ApplicationController
      def show
        respond_to do |format|
          format.html do
            @map_center = Decidim::Bih.map_default_center
            @map_zoom = Decidim::Bih.map_default_zoom
            @report_summary = Decidim::Bih::PublicReportSummary.new(current_organization).call
          end
          format.json { render json: feature_collection }
        end
      end

      private

      def feature_collection
        Decidim::Bih::ReportMapFeatures.new(
          current_organization,
          url_builder: ->(reference) { report_url(reference: reference) },
          url_cache_key: request.host_with_port
        ).call
      end
    end
  end
end

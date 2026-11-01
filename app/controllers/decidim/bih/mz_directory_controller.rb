# frozen_string_literal: true

module Decidim
  module Bih
    # Public, read-only directory of Mjesne zajednice (MZ) for the current
    # organization. Reduces "who do I call" friction: a citizen can browse the
    # city's MZ with the president + phone, and see each MZ's area on a map.
    #
    # Like the other public engine surfaces (ReportsMapController,
    # DonationsController) it inherits from Decidim::ApplicationController so it
    # gets current_organization (resolved from the request host) and the Decidim
    # layout WITHOUT requiring an authenticated user. Everything here is public,
    # org-scoped, and limited to kind="mz".
    #
    # predsjednik/telefon are public-official contact data — fine to display.
    #
    # Routes (mounted under /biceriseno):
    #   GET /mjesne-zajednice              → #index (list of the org's MZ)
    #   GET /mjesne-zajednice/:slug        → #show  (one MZ + boundary map)
    #   GET /mjesne-zajednice/:slug.json   → #show  (MZ boundary as GeoJSON Feature)
    class MzDirectoryController < Decidim::ApplicationController
      # GET /biceriseno/mjesne-zajednice
      # Lists the current organization's MZ, ordered by translated name.
      def index
        @areas = Decidim::Bih::LocalArea
                 .mz
                 .where(decidim_organization_id: current_organization.id)
                 .sort_by { |area| area.translated_name.to_s.downcase }
        @source_label = Decidim::Bih.mz_directory_source_label.to_s.presence
        @last_updated_at = @areas.filter_map(&:updated_at).max
        @support_email = Decidim::Bih.public_support_email.to_s.presence
        @support_name = Decidim::Bih.public_support_name.to_s.presence
      end

      # GET /biceriseno/mjesne-zajednice/:slug(.json)
      # Renders one MZ (404-safe: unknown/foreign/non-MZ slug redirects to index).
      # The boundary (GeoJSON) and a guaranteed-interior center point are exposed
      # for the Leaflet map; both are nil when the MZ has no boundary.
      def show
        @area = find_area
        return redirect_to(mz_directory_path) unless @area

        @boundary = @area.boundary
        @center = @boundary.present? ? Decidim::Bih::Geo::AreaLocator.representative_point(@boundary) : nil
        metadata = @area.metadata.to_h
        @source_label = (metadata["izvor"] || metadata[:izvor]).to_s.presence ||
                        Decidim::Bih.mz_directory_source_label.to_s.presence
        @last_updated_at = @area.updated_at
        @support_email = Decidim::Bih.public_support_email.to_s.presence
        @support_name = Decidim::Bih.public_support_name.to_s.presence

        respond_to do |format|
          format.html
          format.json { render json: boundary_feature }
        end
      end

      private

      def find_area
        Decidim::Bih::LocalArea
          .mz
          .where(decidim_organization_id: current_organization.id)
          .find_by(slug: params[:slug])
      end

      # GeoJSON Feature mirroring the komsiluk #areas shape — geometry + a small
      # set of public properties (name/slug); no citizen data.
      def boundary_feature
        {
          type: "Feature",
          geometry: @boundary,
          properties: {
            slug: @area.slug,
            name: @area.translated_name
          }
        }
      end
    end
  end
end

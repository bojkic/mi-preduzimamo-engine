# frozen_string_literal: true

module Decidim
  module Bih
    # Builds a GeoJSON FeatureCollection of located citizen problem reports
    # ("Bice riseno!") for the public map, scoped to a single organization.
    #
    # PRIVACY: this powers a PUBLIC, anonymous endpoint, so it deliberately
    # exposes ONLY a reviewed public projection of each report. Reporter contact
    # details (reporter_email / reporter_phone) and the raw reporter identity are
    # NEVER serialized here. The reporter-entered free-text `description` is also
    # withheld: it is unmoderated at submission time and a citizen could type
    # their own name/phone into it, so public endpoints never broadcast it. The
    # current public-location policy emits the exact point; the legacy per-report
    # publication flag is retained only for compatibility. Only reports carrying
    # both coordinates are included, and the result is capped so the payload
    # cannot grow without bound.
    class ReportMapFeatures
      # Cap on the number of markers returned (most-recent first). Keeps the
      # JSON payload bounded regardless of how many reports an org accumulates.
      DEFAULT_LIMIT = 500
      CACHE_TTL = 2.minutes
      # Window for the public "recently resolved" map layer: reports marked
      # rijeseno within this many days are flagged so the map can render them as
      # a distinct, celebratory layer (the city's responsiveness made visible).
      RESOLVED_RECENT_DAYS = 30

      # @param organization [Decidim::Organization] tenant to scope to.
      # @param url_builder [#call] maps a report reference to its public status
      #   page URL; injected so routing stays a controller concern.
      # @param limit [Integer] maximum number of markers to return.
      # @param url_cache_key [String] host/route version for cached status URLs.
      def initialize(organization, url_builder:, limit: DEFAULT_LIMIT, url_cache_key: "default")
        @organization = organization
        @url_builder = url_builder
        @limit = limit
        @url_cache_key = url_cache_key
      end

      # @return [Hash] a GeoJSON FeatureCollection.
      def call
        Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { build_collection }
      end

      # Bump when the serialized feature shape or public-location semantics
      # change so old approximate-location payloads are never reused.
      SCHEMA_VERSION = "v8-removed-report-visibility"

      def cache_key
        [
          "decidim_bih", "reports_map", SCHEMA_VERSION, organization.id, limit,
          url_cache_key, cache_version
        ].join("/")
      end

      private

      attr_reader :organization, :url_builder, :limit, :url_cache_key

      def build_collection
        {
          type: "FeatureCollection",
          features: located_reports.map { |report| feature_for(report) }
        }
      end

      def located_reports
        located_scope
          .order(created_at: :desc)
          .limit(limit)
      end

      def located_scope
        Decidim::Bih::Report
          .where(decidim_organization_id: organization.id)
          .publicly_visible
          .where.not(latitude: nil)
          .where.not(longitude: nil)
      end

      def cache_version
        latest = located_scope.maximum(:updated_at)&.utc&.strftime("%Y%m%d%H%M%S%6N") || 0
        "#{located_scope.count}-#{latest}"
      end

      def feature_for(report)
        service_request = Decidim::Bih::ReportServiceRequest.new(report)

        {
          type: "Feature",
          geometry: {
            type: "Point",
            # GeoJSON is [longitude, latitude].
            coordinates: [report.public_longitude, report.public_latitude]
          },
          properties: {
            reference: report.reference,
            category: report.category,
            severity: report.severity,
            status: ReportStatusPresenter.status_key(report),
            public_status: service_request.public_status,
            public_status_label: service_request.public_status_label,
            created_at: report.created_at&.iso8601,
            latitude: report.public_latitude,
            longitude: report.public_longitude,
            location_precision: "exact",
            status_url: url_builder.call(report.reference),
            # PII-safe boolean: drives the distinct "recently resolved" layer on
            # the public map. No timestamp is exposed — only whether the report
            # was resolved inside the recent window.
            resolved_recently: recently_resolved?(report)
          }
        }
      end

      # True when the report is resolved (rijeseno) and reached that status
      # within RESOLVED_RECENT_DAYS. Derived from Report#resolved_at, which uses
      # the status_history with a graceful fallback for legacy rows.
      def recently_resolved?(report)
        return false if report.duplicate?
        return false unless report.status == "rijeseno"

        resolved_at = report.resolved_at
        return false if resolved_at.blank?

        resolved_at >= RESOLVED_RECENT_DAYS.days.ago
      end
    end
  end
end

# frozen_string_literal: true

require "faraday"
require "json"

module Decidim
  module Bih
    module Geo
      # Self-contained geocoder that calls a Nominatim-compatible endpoint to
      # convert a free-text address string into a (lat, lon) pair. The resolved
      # coordinates are used immediately for point-in-polygon lookup and then
      # DISCARDED — the address itself is NEVER stored.
      #
      # DEVIATION FROM SPEC: the spec proposed enabling Decidim's built-in Nominatim
      # geocoding provider (MAPS_PROVIDER=osm). We use a self-contained Faraday
      # client instead to keep the change isolated:
      #   1. Flipping Decidim's MAPS_PROVIDER globally changes the geocoding behavior
      #      for proposal and meeting address fields (where autocomplete is already
      #      configured). A self-contained call does not touch that pipeline.
      #   2. The engine working tree is loaded directly in production; adding a Faraday
      #      call here is simpler and more auditable than threading through Decidim's
      #      Maps abstraction layer.
      #   3. Tests can stub Faraday without affecting the rest of the test suite.
      #
      # Configuration:
      #   Decidim::Bih.geocoder_base_url     — full base URL of a compatible endpoint.
      #   Decidim::Bih.geocoder_search_path  — search route, defaults to /search.
      #   Decidim::Bih.geocoder_extra_headers — optional header auth for contracted
      #                                         compatible services.
      #   DECIDIM_BIH_GEOCODER_BASE_URL      — env fallback for geocoder_base_url.
      #   NOMINATIM_HOST                     — legacy env fallback for the same value.
      # Use a self-hosted or contracted endpoint for high-volume or privacy-sensitive
      # deployments.
      #
      # Returns nil on any error (network failure, timeout, no result) so callers
      # can fall back gracefully.
      class Geocoder
        DEFAULT_HOST = "https://nominatim.openstreetmap.org"
        TIMEOUT = 5 # seconds

        # Geocode `address` (a user-typed string) to { lat:, lon: } or nil.
        # The address string is sent over HTTPS and is not logged or stored.
        def self.coordinates(address)
          new.coordinates(address)
        end

        def coordinates(address)
          return nil if address.blank?

          response = connection.get(geocoder_search_path, {
                                      q: address,
                                      format: "jsonv2",
                                      limit: 1,
                                      addressdetails: 0
                                    })
          return nil unless response.success?

          results = JSON.parse(response.body)
          return nil if results.empty?

          first = results.first
          lat = first["lat"]&.to_f
          lon = first["lon"]&.to_f
          return nil if lat.nil? || lon.nil?

          { lat:, lon: }
        rescue Faraday::Error, JSON::ParserError => e
          # Redact: a Faraday error can embed the request URL whose ?q=<address>
          # query carries the citizen's typed address — never log it raw.
          Rails.logger.error(
            "[Decidim::Bih::Geo::Geocoder] geocoding failed: #{e.class}: " \
            "#{Decidim::Bih::LogRedactor.error_message(e)}"
          )
          nil
        end

        # Candidate search for an explicit citizen choice. Provider address
        # details are transient, just like the original coordinate-only API.
        def self.search(address, limit: 5)
          new.search(address, limit:)
        end

        def search(address, limit: 5)
          return [] if address.blank?

          response = connection.get(geocoder_search_path, q: address, format: "jsonv2", limit: limit.to_i.clamp(1, 5), addressdetails: 1)
          return [] unless response.success?

          Array(JSON.parse(response.body)).first(limit.to_i.clamp(1, 5)).filter_map { |row| search_candidate(row) }
        rescue Faraday::Error, JSON::ParserError => e
          Rails.logger.error("[Decidim::Bih::Geo::Geocoder] candidate lookup failed: #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}")
          []
        end

        private

        def search_candidate(row)
          return unless row.is_a?(Hash)

          lat = Float(row.fetch("lat"))
          lon = Float(row.fetch("lon"))
          return unless lat.finite? && lon.finite? && lat.between?(-90, 90) && lon.between?(-180, 180)

          address = if row["address"].is_a?(Hash)
                      row["address"].slice("house_number", "road", "neighbourhood", "suburb", "village", "town", "city", "municipality", "county",
                                           "country_code")
                    else
                      {}
                    end
          { lat:, lon:, label: row["display_name"].to_s, category: row["category"] || row["class"], type: row["type"],
            address_type: row["addresstype"], address:, precision: candidate_precision(row, address),
            source_id: [row["osm_type"], row["osm_id"]].compact.join(":") }
        rescue ArgumentError, TypeError, KeyError
          nil
        end

        def candidate_precision(row, address)
          return "address" if address["house_number"].present?
          return "street" if (row["category"] || row["class"]) == "highway" || row["addresstype"] == "road"
          return "place" if %w(place boundary).include?(row["category"] || row["class"])

          "approximate"
        end

        def connection
          @connection ||= Faraday.new(url: geocoder_base_url) do |f|
            # Public Nominatim requires a descriptive User-Agent. Private or
            # contracted compatible endpoints should accept the same header.
            f.headers["User-Agent"] = Decidim::Bih.geocoder_user_agent
            geocoder_extra_headers.each do |key, value|
              f.headers[key] = value
            end
            f.options.timeout = TIMEOUT
            f.options.open_timeout = TIMEOUT
            f.adapter Faraday.default_adapter
          end
        end

        def geocoder_base_url
          Decidim::Bih.geocoder_base_url.presence ||
            ENV.fetch("DECIDIM_BIH_GEOCODER_BASE_URL", nil).presence ||
            ENV.fetch("NOMINATIM_HOST", nil).presence ||
            DEFAULT_HOST
        end

        def geocoder_search_path
          path = Decidim::Bih.geocoder_search_path.to_s.presence || "/search"
          path.start_with?("/") ? path : "/#{path}"
        end

        def geocoder_extra_headers
          Decidim::Bih.geocoder_extra_headers.to_h.filter_map do |key, value|
            next if key.blank? || value.blank?

            [key.to_s, value.to_s]
          end.to_h
        end
      end
    end
  end
end

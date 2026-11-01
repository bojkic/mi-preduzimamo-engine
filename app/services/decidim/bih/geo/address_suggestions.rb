# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # A candidate list is not a home assignment. Broad provider results only
      # move the map; the citizen must choose their neighbourhood there.
      class AddressSuggestions
        def initialize(organization:, geocoder: Geocoder, local_lookup: Decidim::Bih.local_address_lookup)
          @organization = organization
          @geocoder = geocoder
          @local_lookup = local_lookup
        end

        def call(query)
          return response([]) if query.blank?

          local = @local_lookup&.call(query:, organization: @organization)
          return response(local, "local") if local.present?

          candidates = @geocoder.search(query).filter_map { |candidate| provider_candidate(candidate) }
          response(candidates, "provider")
        end

        private

        def response(candidates, source = nil)
          { found: candidates.any?, candidates:, source:, requires_selection: candidates.any? }
        end

        def provider_candidate(candidate)
          @locator ||= AreaLocator.new
          located = @locator.resolve(lat: candidate.fetch(:lat), lon: candidate.fetch(:lon), organization: @organization)
          return unless located[:komsiluk]

          candidate.merge(source: "provider", komsiluk_id: located[:komsiluk].id, komsiluk_name: located[:komsiluk].translated_name,
                          mz_name: located[:mz]&.translated_name, requires_map_confirmation: candidate.fetch(:precision) != "address")
        end
      end
    end
  end
end

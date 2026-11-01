# frozen_string_literal: true

module Decidim
  module Bih
    module Postal
      # On successful postal_letter authorization grant, geocode the verified
      # mailing address once and update the citizen's CitizenProfile komšiluk
      # with source: "postal" (overrides a prior self-declared value).
      #
      # The mailing address is read from the authorization's verification_metadata
      # and is NEVER re-stored or logged. It is used in-memory for a single
      # Nominatim call and then discarded. Only the resolved komsiluk_id is
      # persisted (in CitizenProfile), matching the self-service pickers' contract.
      #
      # Returns :updated, :not_geocoded, or :no_area on outcomes.
      class PostalKomsilukService
        class << self
          # Called from outside (e.g. via a granted authorization row that still
          # has verification_metadata set — for direct invocations in tests or
          # manual flows).
          #
          # NOTE: The production after_commit hook calls +call_with_address+
          # directly (because grant! clears verification_metadata before commit).
          # +call+ is only useful when the authorization row still holds the
          # address in verification_metadata (pre-grant state). If the address
          # is blank (post-grant or never set), this is a no-op returning
          # :no_address so callers are never silently misled.
          def call(authorization)
            address = authorization.verification_metadata["address"]
            return :no_address if address.blank?

            call_with_address(user: authorization.user, address: address)
          end

          # Called from the after_commit hook where grant! has already cleared
          # verification_metadata. The pre-grant address is passed explicitly.
          def call_with_address(user:, address:)
            new(user:, address:).call
          end
        end

        def initialize(user:, address:)
          @user = user
          @address = address
          @organization = user.organization
        end

        def call
          return :no_address if @address.blank?

          coords = Decidim::Bih::Geo::Geocoder.coordinates(@address)
          return :not_geocoded if coords.nil?

          result = Decidim::Bih::Geo::AreaLocator.new.locate_komsiluk(
            lat: coords[:lat],
            lon: coords[:lon],
            organization: @organization
          )
          return :no_area if result.nil?

          # Pass the point-resolved MZ explicitly so assign_komsiluk! does not
          # fall back to primary_mz_slug (decoupled model — MZ from PIP wins).
          profile = CitizenProfile.for_user(@user, organization: @organization)
          profile.assign_komsiluk!(result[:komsiluk], source: "postal", resolved_mz: result[:mz])
          :updated
        rescue StandardError => e
          Rails.logger.error(
            "[PostalKomsilukService] failed for user #{@user&.id}: #{e.class}: #{e.message}"
          )
          :error
        end
      end
    end
  end
end

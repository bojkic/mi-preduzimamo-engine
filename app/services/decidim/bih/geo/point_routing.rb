# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Provides geographic routing helpers: given a coordinate point, resolve
      # the MZ and komšiluk slugs; optionally retrieve MZ council contact info
      # and a komšiluk's overlapping MZ presidents.
      #
      # WIRED (W6.3): Sistem48::ReportMailer#mz_context_lines calls #resolve +
      # #mz_contact to ADDITIVELY enrich a forwarded report with its MZ name and
      # president/phone. The product decision was additive — the city's central
      # Sistem 48 intake stays the authoritative routing target; the MZ context
      # is informational. The lookup degrades to a no-op (no geo data / point
      # outside every MZ / no org), so reports without resolvable coordinates
      # forward exactly as before.
      #
      # Usage:
      #   result = Decidim::Bih::Geo::PointRouting.resolve(
      #     lat: 44.756, lon: 19.214, organization: org
      #   )
      #   # => { mz_slug: "mz-centar", komsiluk_slug: "komsiluk-1" }
      #
      #   info = Decidim::Bih::Geo::PointRouting.mz_contact(slug: "mz-centar", organization: org)
      #   # => { slug: "mz-centar", name: "MZ Centar", predsjednik: "...", telefon: "..." }
      #
      #   presidents = Decidim::Bih::Geo::PointRouting.komsiluk_mz_presidents(
      #     komsiluk_slug: "komsiluk-1", organization: org
      #   )
      #   # => [{ slug: "mz-centar", predsjednik: "...", telefon: "..." }, ...]
      class PointRouting
        class << self
          # Resolve a coordinate point to { mz_slug:, komsiluk_slug: }.
          # Both values are nil when the point falls outside all known polygons.
          def resolve(lat:, lon:, organization:)
            result = AreaLocator.new.resolve(lat:, lon:, organization:)
            {
              mz_slug: result[:mz]&.slug,
              komsiluk_slug: result[:komsiluk]&.slug
            }
          end

          # Return contact info for a single MZ by slug.
          # Returns nil when the slug is not found in the organisation.
          def mz_contact(slug:, organization:)
            mz = Decidim::Bih::LocalArea.mz.find_by(
              decidim_organization_id: organization.id,
              slug:
            )
            return nil unless mz

            {
              slug: mz.slug,
              name: mz.translated_name,
              predsjednik: mz.predsjednik,
              telefon: mz.telefon
            }
          end

          # Return the council contact info for every MZ that overlaps a given
          # komšiluk. Useful for general-proposal notification fan-out.
          # Returns [] when the komšiluk slug is not found or has no overlapping MZ.
          def komsiluk_mz_presidents(komsiluk_slug:, organization:)
            komsiluk = Decidim::Bih::LocalArea.komsiluci.find_by(
              decidim_organization_id: organization.id,
              slug: komsiluk_slug
            )
            return [] unless komsiluk

            komsiluk.overlapping_mz.map do |mz|
              {
                slug: mz.slug,
                name: mz.translated_name,
                predsjednik: mz.predsjednik,
                telefon: mz.telefon
              }
            end
          end
        end
      end
    end
  end
end

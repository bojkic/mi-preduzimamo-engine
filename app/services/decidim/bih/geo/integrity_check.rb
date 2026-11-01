# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Read-only health check over an organization's geo reference data
      # (MZ + komšiluci). It flags the silent routing-data corruption classes that
      # a GeoJSON re-import can introduce WITHOUT mutating any record — run it
      # before and after every `decidim_bih:geo:import_areas` run.
      #
      # Issue classes (audit new-feature #10):
      #
      #   :empty_overlaps         komšiluci with an EMPTY overlapping_mz_slugs.
      #                           Almost always means relations were never computed
      #                           (forgot `compute_relations`) or were cleared by a
      #                           re-import and not recomputed.
      #
      #   :degenerate_boundary    areas whose boundary is nil or geometrically
      #                           degenerate — detected via AreaLocator.
      #                           representative_point returning nil. Such an area
      #                           can never match a point and never renders a map.
      #
      #   :dangling_primary_mz    komšiluci whose primary_mz_slug references an MZ
      #                           slug that does not exist in this org (a dangling
      #                           pointer, e.g. the MZ was renamed/removed).
      #
      #   :point_outside_boundary areas whose STORED centroid (centroid_lat/lon) is
      #                           not actually inside their own boundary. This is
      #                           the stale-after-MZ-reimport class: the boundary
      #                           was re-shaped but the centroid was left pointing
      #                           at the old geometry, so map defaults land outside
      #                           the polygon.
      #
      # Usage:
      #   issues = Decidim::Bih::Geo::IntegrityCheck.new(organization).call
      #   # => {
      #   #      empty_overlaps:         [{ slug:, kind:, message: }, ...],
      #   #      degenerate_boundary:    [...],
      #   #      dangling_primary_mz:    [...],
      #   #      point_outside_boundary: [...]
      #   #    }
      #
      # Every value is an Array (empty when clean). Each entry is a Hash with
      # :slug, :kind and a short human-readable :message. Org-scoped: only areas
      # belonging to the passed organization are examined and referenced.
      class IntegrityCheck
        ISSUE_TYPES = [
          :empty_overlaps,
          :degenerate_boundary,
          :dangling_primary_mz,
          :point_outside_boundary
        ].freeze

        def initialize(organization)
          @organization = organization
          @locator = AreaLocator.new
        end

        # Returns a Hash keyed by ISSUE_TYPES; each value is an Array of issue
        # Hashes ({ slug:, kind:, message: }). Performs no writes.
        def call
          issues = ISSUE_TYPES.index_with { [] }

          areas.each do |area|
            check_degenerate_boundary(area, issues)
            check_point_outside_boundary(area, issues)
          end

          komsiluci.each do |area|
            check_empty_overlaps(area, issues)
            check_dangling_primary_mz(area, issues)
          end

          issues
        end

        private

        attr_reader :organization, :locator

        def areas
          @areas ||= LocalArea.where(decidim_organization_id: organization.id).to_a
        end

        def komsiluci
          @komsiluci ||= areas.select { |a| a.kind == "komsiluk" }
        end

        # Set of all MZ slugs in this org, used to detect dangling references.
        def mz_slugs
          @mz_slugs ||= areas.select { |a| a.kind == "mz" }.to_set(&:slug)
        end

        # 1. komšiluk with no computed overlapping MZ.
        def check_empty_overlaps(area, issues)
          return if Array(area.overlapping_mz_slugs).any?

          issues[:empty_overlaps] << issue(
            area,
            "overlapping_mz_slugs is empty — relations likely never computed (run compute_relations)."
          )
        end

        # 2. nil / degenerate boundary: representative_point can't be derived.
        def check_degenerate_boundary(area, issues)
          return unless AreaLocator.representative_point(area.boundary).nil?

          detail = area.boundary.nil? ? "boundary is nil" : "boundary is degenerate (no representative point)"
          issues[:degenerate_boundary] << issue(
            area,
            "#{detail} — area can never be located or mapped."
          )
        end

        # 3. komšiluk primary_mz_slug pointing at a non-existent MZ.
        def check_dangling_primary_mz(area, issues)
          slug = area.primary_mz_slug
          return if slug.blank?
          return if mz_slugs.include?(slug)

          issues[:dangling_primary_mz] << issue(
            area,
            "primary_mz_slug \"#{slug}\" references an MZ that does not exist in this organization."
          )
        end

        # 4. stored centroid not inside the area's own boundary.
        # Skips areas without a usable boundary (already flagged as degenerate) and
        # areas with no stored centroid (nothing to validate).
        def check_point_outside_boundary(area, issues)
          return unless area.boundary.is_a?(Hash)
          return if AreaLocator.representative_point(area.boundary).nil?
          return if area.centroid_lat.nil? || area.centroid_lon.nil?

          # boundary is GeoJSON (lon, lat); point_in_geom? expects (lon, lat).
          return if locator.point_in_geom?(area.centroid_lon, area.centroid_lat, area.boundary)

          issues[:point_outside_boundary] << issue(
            area,
            "stored centroid (#{area.centroid_lat}, #{area.centroid_lon}) is outside its own boundary " \
            "— likely stale after an MZ re-import."
          )
        end

        def issue(area, message)
          { slug: area.slug, kind: area.kind, message: }
        end
      end
    end
  end
end

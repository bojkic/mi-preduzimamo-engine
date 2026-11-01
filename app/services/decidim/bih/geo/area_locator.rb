# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Resolves a (lat, lon) point to LocalArea records using a pure-Ruby
      # ray-casting point-in-polygon algorithm.
      #
      # DEVIATION FROM SPEC: the spec suggested using the `rgeo`/`rgeo-geojson`
      # gems. We use pure Ruby instead to avoid a native-extension / GEOS
      # dependency on the production engine working tree (the local bundle override
      # means the engine is loaded directly from its working tree, with no
      # platform-native extension pre-compiled). A ray-casting PIP over a city's
      # polygon count (~50–200 polygons) is fast enough in plain Ruby. If the
      # polygon count ever grows to tens of thousands, revisit the gem approach.
      #
      # Algorithm: even-odd rule (ray casting) over GeoJSON coordinate rings,
      # treating (lon, lat) as planar (X, Y). This is accurate for a single
      # city's bounding area where the planar approximation error is negligible.
      #
      # Supports:
      #   - GeoJSON Polygon (exterior ring + optional hole rings)
      #   - GeoJSON MultiPolygon (collection of polygons, each with optional holes)
      # A point inside a hole is NOT inside the polygon.
      #
      # Usage:
      #   locator = Decidim::Bih::Geo::AreaLocator.new
      #   result  = locator.locate_komsiluk(lat: 44.756, lon: 19.214, organization: org)
      #   # => { komsiluk: <LocalArea>, mz: <LocalArea|nil> } or nil
      #
      #   mz      = locator.locate_mz(lat: 44.756, lon: 19.214, organization: org)
      #   # => <LocalArea> or nil
      #
      #   result  = locator.resolve(lat: 44.756, lon: 19.214, organization: org)
      #   # => { mz: <LocalArea|nil>, komsiluk: <LocalArea|nil> }
      class AreaLocator
        class << self
          # A guaranteed-interior representative point [lat, lon] for a GeoJSON
          # Polygon/MultiPolygon (PostGIS ST_PointOnSurface-style). The naive
          # average-of-coordinates centroid can fall OUTSIDE a concave/crescent
          # polygon (the cause of off-centre map defaults for ~2 Bijeljina MZ);
          # this returns the area-weighted centroid when it is inside, otherwise
          # the midpoint of the widest interior span on a horizontal scanline —
          # always inside the polygon. Returns nil for a degenerate geometry.
          def representative_point(geometry)
            return nil unless geometry.is_a?(Hash)

            polygons = polygons_of(geometry)
            return nil if polygons.empty?

            rings = polygons.max_by { |poly| ring_area(poly.first).abs }
            outer = rings.first
            return nil unless outer.is_a?(Array) && outer.size >= 3

            locator = new
            centroid = polygon_centroid(outer)
            return [centroid[1].round(6), centroid[0].round(6)] if centroid && locator.point_in_geom?(centroid[0], centroid[1], geometry)

            point = point_on_surface(rings, centroid, locator, geometry)
            return nil unless point

            [point[1].round(6), point[0].round(6)]
          end

          # Longitude intervals that are inside a Polygon/MultiPolygon at the
          # supplied latitude. Each pair is left-inclusive and right-exclusive,
          # matching #ray_cast's boundary convention. RelationsComputer uses
          # this scanline form to classify a fixed grid without re-walking every
          # polygon edge for every individual point.
          def longitude_intervals_at(lat, geometry)
            return [] unless geometry.is_a?(Hash)

            polygons_of(geometry).flat_map do |rings|
              horizontal_crossings(rings, lat.to_f).each_slice(2).filter_map do |left, right|
                [left, right] if right
              end
            end
          end

          private

          # GeoJSON polygons as [[outer_ring, *hole_rings], ...].
          def polygons_of(geometry)
            list = case geometry["type"]
                   when "Polygon" then [geometry["coordinates"]]
                   when "MultiPolygon" then Array(geometry["coordinates"])
                   else []
                   end
            list.select { |poly| poly.is_a?(Array) && poly.first.is_a?(Array) }
          end

          # Shoelace signed area of a closed ring of [lon, lat] pairs.
          def ring_area(ring)
            return 0.0 unless ring.is_a?(Array) && ring.size >= 3

            sum = 0.0
            (0...(ring.size - 1)).each do |i|
              x1 = ring[i][0].to_f
              y1 = ring[i][1].to_f
              x2 = ring[i + 1][0].to_f
              y2 = ring[i + 1][1].to_f
              sum += (x1 * y2) - (x2 * y1)
            end
            sum / 2.0
          end

          # Area-weighted centroid [lon, lat] of a closed ring; falls back to the
          # simple average for a degenerate (zero-area) ring.
          def polygon_centroid(ring)
            area = ring_area(ring)
            return simple_average(ring) if area.abs < 1e-12

            cx = 0.0
            cy = 0.0
            (0...(ring.size - 1)).each do |i|
              x1 = ring[i][0].to_f
              y1 = ring[i][1].to_f
              x2 = ring[i + 1][0].to_f
              y2 = ring[i + 1][1].to_f
              cross = (x1 * y2) - (x2 * y1)
              cx += (x1 + x2) * cross
              cy += (y1 + y2) * cross
            end
            [cx / (6.0 * area), cy / (6.0 * area)]
          end

          def simple_average(ring)
            pts = ring[0...-1].presence || ring
            [pts.sum { |c| c[0].to_f } / pts.size, pts.sum { |c| c[1].to_f } / pts.size]
          end

          # Midpoint [lon, lat] of the widest interior horizontal span, scanning
          # the centroid latitude plus several latitudes across the polygon, so a
          # concave shape still yields an interior point. Holes are excluded
          # because the even-odd pairing spans all rings of the polygon.
          def point_on_surface(rings, centroid, locator, geometry)
            lats = rings.first.map { |c| c[1].to_f }
            ymin = lats.min
            ymax = lats.max
            candidates = []
            candidates << centroid[1] if centroid
            1.upto(9) { |k| candidates << (ymin + ((ymax - ymin) * k / 10.0)) }

            best = nil
            best_width = -1.0
            candidates.each do |lat_y|
              xs = horizontal_crossings(rings, lat_y)
              xs.each_slice(2) do |x1, x2|
                next unless x2
                next unless (x2 - x1) > best_width

                mid = (x1 + x2) / 2.0
                next unless locator.point_in_geom?(mid, lat_y, geometry)

                best = [mid, lat_y]
                best_width = x2 - x1
              end
            end
            best
          end

          # Sorted x where a horizontal line at `lat_y` crosses any ring edge.
          def horizontal_crossings(rings, lat_y)
            xs = []
            rings.each do |ring|
              next unless ring.is_a?(Array)

              (0...(ring.size - 1)).each do |i|
                y1 = ring[i][1].to_f
                y2 = ring[i + 1][1].to_f
                next if (y1 > lat_y) == (y2 > lat_y)

                x1 = ring[i][0].to_f
                x2 = ring[i + 1][0].to_f
                t = (lat_y - y1) / (y2 - y1)
                xs << (x1 + (t * (x2 - x1)))
              end
            end
            xs.sort
          end
        end

        # Locate the MZ for (lat, lon) within the given organization.
        # Returns the MZ LocalArea or nil.
        def locate_mz(lat:, lon:, organization:)
          areas = mz_for(organization)
          areas.find { |area| point_in_area?(lon, lat, area) }
        end

        # Locate the komšiluk for (lat, lon) within the given organization.
        # Returns a Hash with :komsiluk and :mz keys, or nil if no match.
        # The :mz value is now resolved INDEPENDENTLY by point (not via parent).
        def locate_komsiluk(lat:, lon:, organization:)
          areas = komsiluci_for(organization)
          match = areas.find { |area| point_in_area?(lon, lat, area) }
          return nil unless match

          { komsiluk: match, mz: locate_mz(lat:, lon:, organization:) }
        end

        # Resolve both MZ and komšiluk INDEPENDENTLY by point-in-polygon.
        # Returns { mz: <LocalArea|nil>, komsiluk: <LocalArea|nil> }.
        # Neither result is derived from the other — they are always resolved
        # against their own polygon sets.
        def resolve(lat:, lon:, organization:)
          {
            mz: locate_mz(lat:, lon:, organization:),
            komsiluk: locate_komsiluk(lat:, lon:, organization:)&.dig(:komsiluk)
          }
        end

        # Test whether a raw GeoJSON geometry Hash contains the point (lon, lat).
        # Exposed as a public method so RelationsComputer can reuse the same PIP
        # without duplicating the ray-casting logic.
        def point_in_geom?(lon, lat, geom)
          return false unless geom.is_a?(Hash)

          case geom["type"]
          when "Polygon"
            point_in_polygon?(lon, lat, geom["coordinates"])
          when "MultiPolygon"
            geom["coordinates"].any? { |polygon_rings| point_in_polygon?(lon, lat, polygon_rings) }
          else
            false
          end
        end

        private

        # Memoized MZ areas with non-nil boundaries for the given org.
        def mz_for(organization)
          @mz ||= {}
          @mz[organization.id] ||= Decidim::Bih::LocalArea
                                   .mz
                                   .where(decidim_organization_id: organization.id)
                                   .where.not(boundary: nil)
                                   .to_a
        end

        # Memoized komšiluci with non-nil boundaries.
        def komsiluci_for(organization)
          @komsiluci ||= {}
          @komsiluci[organization.id] ||= Decidim::Bih::LocalArea
                                          .komsiluci
                                          .where(decidim_organization_id: organization.id)
                                          .where.not(boundary: nil)
                                          .to_a
        end

        # True if the GeoJSON geometry stored in `area.boundary` contains
        # the point (point_x=lon, point_y=lat). Handles Polygon and MultiPolygon.
        def point_in_area?(point_x, point_y, area)
          point_in_geom?(point_x, point_y, area.boundary)
        end

        # GeoJSON Polygon coordinates: [[exterior_ring], [hole_ring], ...]
        # A point is "inside" if it is within the exterior ring and outside
        # every hole ring (interior rings exclude via XOR of the even-odd result).
        def point_in_polygon?(point_x, point_y, rings)
          return false if rings.blank?

          exterior_ring = rings[0]
          return false unless ray_cast(point_x, point_y, exterior_ring)

          # If the point is inside any hole, it is outside the polygon.
          hole_rings = rings[1..]
          hole_rings.none? { |hole| ray_cast(point_x, point_y, hole) }
        end

        # Ray-casting (even-odd rule) for a single coordinate ring.
        # `ring` is an Array of [lon, lat] pairs (GeoJSON order).
        # Returns true if the point (point_x, point_y) is inside the ring.
        def ray_cast(point_x, point_y, ring)
          # boundary is unvalidated jsonb; a nil / empty / degenerate ring can't
          # contain an area, so skip it rather than crash the whole lookup.
          return false unless ring.is_a?(Array) && ring.size >= 3

          inside = false
          n = ring.size

          j = n - 1
          (0...n).each do |i|
            xi = ring[i][0].to_f
            yi = ring[i][1].to_f
            xj = ring[j][0].to_f
            yj = ring[j][1].to_f

            intersects = ((yi > point_y) != (yj > point_y)) &&
                         (point_x < (((xj - xi) * (point_y - yi)) / (yj - yi)) + xi)
            inside = !inside if intersects
            j = i
          end

          inside
        end
      end
    end
  end
end

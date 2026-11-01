# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Computes MZ↔komšiluk relations by grid-sampling the komšiluk's bounding
      # box, using AreaLocator's equivalent pure-Ruby scanline intervals.
      #
      # Algorithm (supersedes the handoff brief's Python/shapely script):
      #   For each komšiluk K with a non-nil boundary:
      #     1. Build a grid of GRID_N×GRID_N sample points over K's bbox.
      #     2. Keep only points inside K (scanline test on K's polygon).
      #     3. Discard MZ polygons whose bounding boxes cannot overlap K.
      #     4. For each remaining MZ M: count sample points also inside M.
      #     5. overlapping_mz_slugs = all MZ with ≥ MIN_HITS in-K sample points.
      #     6. primary_mz_slug = MZ with the most in-K hits.
      #
      # Grid density: GRID_N = 80 gives up to 6,400 candidate points per bbox.
      # After clipping to the komšiluk polygon, the actual sample count is
      # proportional to area.
      #
      # Accuracy note: the planar-approximation error at Bijeljina's latitude
      # (~44.7°N) is < 0.1% for coordinate distances — negligible for slug ranking.
      #
      # This is zero-dependency (no GEOS / rgeo) and reuses AreaLocator's
      # public .longitude_intervals_at method so polygon scanline logic lives in
      # exactly one place.
      class RelationsComputer
        # Grid side length: GRID_N² candidate points per bbox.
        # 80 gives up to 6,400 candidates — denser sampling for thin/small polygons.
        GRID_N = 80

        # Minimum in-komšiluk sample hits for an MZ to count as overlapping.
        #
        # A single grid point landing on an MZ boundary (a sliver) would
        # spuriously register an overlap with MIN_HITS = 1. We therefore require
        # at least 2 hits AND at least 1 % of the total in-komšiluk sample count
        # (whichever is larger). This suppresses boundary slivers while still
        # registering genuine partial overlaps:
        #   - A komšiluk with 400 in-polygon samples needs ≥ 4 hits per MZ.
        #   - A small komšiluk with only 10 in-polygon samples still needs ≥ 2.
        # Adjust if real-world imports produce false negatives for genuine thin
        # overlaps — see docs/operations/komsiluk-geojson-format.md for guidance.
        MIN_HITS_ABSOLUTE = 2
        MIN_HITS_FRACTION = 0.01 # 1 % of in-komšiluk sample count

        def initialize(organization)
          @organization = organization
        end

        # Compute and persist relations for all komšiluci in the organisation.
        # Returns { updated:, skipped: }.
        def compute!
          mz_areas = load_areas("mz").filter_map do |area|
            bbox = bounding_box(area.boundary)
            [area, bbox] if bbox
          end
          komsiluci = load_areas("komsiluk")

          updated = 0
          skipped = 0

          komsiluci.each do |komsiluk|
            unless komsiluk.boundary.is_a?(Hash)
              skipped += 1
              next
            end

            hits, sample_count = count_mz_hits(komsiluk, mz_areas)
            # Never require more hits than samples taken (a 1-point interior
            # fallback would otherwise fall below the absolute minimum). Not
            # Comparable#clamp: the lower bound can exceed sample_count here.
            desired = [MIN_HITS_ABSOLUTE, (MIN_HITS_FRACTION * sample_count).ceil].max
            threshold = [desired, sample_count].min
            overlapping = hits.select { |_slug, count| count >= threshold }
            # primary is the strongest overlap WITHIN the thresholded set, so it is
            # always one of overlapping_mz_slugs (never a sub-threshold sliver).
            primary = overlapping.max_by { |_slug, count| count }&.first
            overlapping = overlapping.keys

            # update_columns is intentional: these are computed geometry fields,
            # not user-submitted data, and we want to skip callbacks + validations.
            komsiluk.update_columns( # rubocop:disable Rails/SkipsModelValidations
              primary_mz_slug: primary,
              overlapping_mz_slugs: overlapping
            )
            updated += 1
          end

          { updated:, skipped: }
        end

        private

        def load_areas(kind)
          Decidim::Bih::LocalArea
            .where(kind:, decidim_organization_id: @organization.id)
            .where.not(boundary: nil)
            .to_a
        end

        # Returns [hits_hash, sample_count] where hits_hash is
        # { mz_slug => hit_count } for all MZ with any hits (threshold filtering
        # is done by the caller using the returned sample_count).
        def count_mz_hits(komsiluk, mz_areas)
          bbox = bounding_box(komsiluk.boundary)
          return [{}, 0] unless bbox

          # Real municipal imports contain tens of thousands of vertices. Testing
          # every sample against every MZ made the first full 70-MZ/92-komšiluk
          # relation pass prohibitively slow. Bounding boxes are a lossless
          # rejection filter: disjoint boxes cannot contain the same point.
          candidate_mz_areas = mz_areas.select { |_mz, mz_bbox| boxes_intersect?(bbox, mz_bbox) }
          return [{}, 0] if candidate_mz_areas.empty?

          sample_points = relation_sample_points(komsiluk.boundary, bbox)
          return [{}, 0] if sample_points.empty?

          [mz_hits(candidate_mz_areas, sample_points), sample_points.size]
        end

        def relation_sample_points(boundary, bbox)
          sample_points = grid_points_in_geom(boundary, bbox)
          return sample_points if sample_points.any?

          # A thin/small komšiluk can slip between all grid cell-centres, which
          # would silently leave it with NO MZ relations. Fall back to a single
          # guaranteed-interior point so it still resolves its containing MZ.
          # representative_point returns [lat, lon]; the grid uses [lon, lat].
          representative = AreaLocator.representative_point(boundary)
          representative ? [[representative[1], representative[0]]] : []
        end

        def mz_hits(candidate_mz_areas, sample_points)
          hits = {}
          sample_rows = sample_points.group_by { |_lon, lat| lat }
          candidate_mz_areas.each do |mz, mz_bbox|
            count = count_mz_row_hits(sample_rows, mz.boundary, mz_bbox)
            hits[mz.slug] = count if count.positive?
          end
          hits
        end

        def count_mz_row_hits(sample_rows, boundary, bbox)
          sample_rows.sum do |lat, points|
            next 0 if lat < bbox[1] || lat > bbox[3]

            intervals = AreaLocator.longitude_intervals_at(lat, boundary)
            points.count do |lon, _point_lat|
              point_in_box?(lon, lat, bbox) && point_in_intervals?(lon, intervals)
            end
          end
        end

        # Compute the bounding box [min_lon, min_lat, max_lon, max_lat] of a
        # GeoJSON Polygon or MultiPolygon. Returns nil if geometry is invalid.
        def bounding_box(geom)
          coords = case geom["type"]
                   when "Polygon" then geom.dig("coordinates", 0)
                   when "MultiPolygon" then geom["coordinates"].flat_map { |rings| rings[0] }
                   end
          return nil unless coords.is_a?(Array) && coords.any?

          lons = coords.map { |c| c[0].to_f }
          lats = coords.map { |c| c[1].to_f }
          [lons.min, lats.min, lons.max, lats.max]
        end

        def boxes_intersect?(left, right)
          left[0] <= right[2] && left[2] >= right[0] &&
            left[1] <= right[3] && left[3] >= right[1]
        end

        def point_in_box?(lon, lat, bbox)
          lon >= bbox[0] && lon <= bbox[2] && lat >= bbox[1] && lat <= bbox[3]
        end

        def point_in_intervals?(lon, intervals)
          intervals.any? { |left, right| lon >= left && lon < right }
        end

        # Build a uniform grid over the bbox and return only points inside `geom`.
        # Uses half-step offset so points land at cell centres rather than edges.
        # Returns an Array of [lon, lat] pairs.
        def grid_points_in_geom(geom, bbox)
          min_lon, min_lat, max_lon, max_lat = bbox
          lon_step = (max_lon - min_lon) / GRID_N.to_f
          lat_step = (max_lat - min_lat) / GRID_N.to_f

          # Guard against degenerate zero-area bbox (e.g. single-point geometry).
          return [] if lon_step.zero? || lat_step.zero?

          half_lon = lon_step / 2.0
          half_lat = lat_step / 2.0

          longitudes = GRID_N.times.map { |i| min_lon + half_lon + (i * lon_step) }
          points = []
          GRID_N.times do |j|
            lat = min_lat + half_lat + (j * lat_step)
            intervals = AreaLocator.longitude_intervals_at(lat, geom)
            longitudes.each do |lon|
              points << [lon, lat] if point_in_intervals?(lon, intervals)
            end
          end
          points
        end
      end
    end
  end
end

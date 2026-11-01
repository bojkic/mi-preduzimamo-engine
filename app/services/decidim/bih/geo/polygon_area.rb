# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Planar polygon area and polygon∩polygon area by SCANLINE INTEGRATION.
      #
      # DEVIATION FROM THE OBVIOUS TOOL: no PostGIS on this server, and neither
      # rgeo nor shapely is available. Decidim::Bih::Geo::AreaLocator already
      # documents why: production loads the engine working tree directly, so a
      # native extension would have no pre-compiled build. Same reasoning here.
      #
      # Method: for each horizontal scanline y, collect the x-crossings of every
      # non-horizontal edge, sort them, and pair them up (even-odd rule) into the
      # intervals lying inside the polygon. Holes fall out of the even-odd rule
      # for free. Exact in x, discretised in y.
      #
      # Coordinates are GeoJSON (lon, lat) treated as planar (x, y). Over a single
      # city the planar distortion is negligible, and it CANCELS ENTIRELY in the
      # ratio of two areas — which is the only thing this module is used for.
      module PolygonArea
        SCANLINES = 600

        module_function

        # Every non-horizontal edge as [x1, y1, x2, y2]. Horizontal edges are
        # dropped: they contribute no crossing under the even-odd rule.
        def edges(geometry)
          rings(geometry).flat_map do |ring|
            points = ring.map { |c| [c[0].to_f, c[1].to_f] }
            points = points + [points.first] if points.size > 1 && points.first != points.last
            points.each_cons(2).filter_map do |(a, b)|
              [a[0], a[1], b[0], b[1]] unless a[1] == b[1]
            end
          end
        end

        # The x-intervals of the polygon on scanline y, as sorted [x0, x1] pairs.
        # Half-open edge test (y >= lo && y < hi) so a vertex shared by two edges
        # is counted exactly once.
        def spans_at(edges, y)
          xs = []
          edges.each do |(x1, y1, x2, y2)|
            lo, hi = y1 < y2 ? [y1, y2] : [y2, y1]
            next unless y >= lo && y < hi

            xs << (x1 + ((x2 - x1) * (y - y1) / (y2 - y1)))
          end
          xs.sort!
          xs.each_slice(2).filter_map { |a, b| [a, b] if b }
        end

        def area(geometry, scanlines: SCANLINES)
          integrate(geometry, scanlines:) { |spans, _y| span_length(spans) }
        end

        # Fraction of `geometry`'s area that falls inside `clip`, in 0.0..1.0.
        # `clip` may be a GeoJSON Hash or a prebuilt ClipIndex.
        def intersection_area(geometry, clip, scanlines: SCANLINES)
          index = clip.is_a?(ClipIndex) ? clip : ClipIndex.new(clip)
          integrate(geometry, scanlines:) { |spans, y| overlap_length(spans, index.spans_at(y)) }
        end

        def covered_ratio(geometry, clip, scanlines: SCANLINES)
          total = area(geometry, scanlines:)
          return 0.0 if total <= 0.0

          intersection_area(geometry, clip, scanlines:) / total
        end

        def rings(geometry)
          return [] unless geometry.is_a?(Hash)

          coordinates = geometry["coordinates"] || geometry[:coordinates]
          return [] unless coordinates.is_a?(Array)

          case geometry["type"] || geometry[:type]
          when "Polygon" then coordinates
          when "MultiPolygon" then coordinates.flatten(1)
          else []
          end
        end

        def integrate(geometry, scanlines:)
          ys = rings(geometry).flatten(1).map { |c| c[1].to_f }
          return 0.0 if ys.empty?

          y_min, y_max = ys.minmax
          return 0.0 if y_max <= y_min

          polygon_edges = edges(geometry)
          dy = (y_max - y_min) / scanlines
          total = 0.0
          scanlines.times do |i|
            y = y_min + ((i + 0.5) * dy)
            spans = spans_at(polygon_edges, y)
            next if spans.empty?

            total += yield(spans, y) * dy
          end
          total
        end

        def span_length(spans)
          spans.sum { |(a, b)| b - a }
        end

        def overlap_length(a_spans, b_spans)
          return 0.0 if b_spans.empty?

          total = 0.0
          a_spans.each do |(a0, a1)|
            b_spans.each do |(b0, b1)|
              low = a0 > b0 ? a0 : b0
              high = a1 < b1 ? a1 : b1
              total += high - low if high > low
            end
          end
          total
        end

        # Buckets a clip polygon's edges into horizontal bands so a scanline only
        # tests the edges that can cross it. Classifying 92 komšiluci against the
        # ~1400-edge Bijeljina frame is ~78M edge tests unindexed; this makes it
        # a few hundred thousand, turning minutes into seconds.
        class ClipIndex
          BANDS = 2000

          def initialize(geometry)
            @edges = PolygonArea.edges(geometry)
            ys = @edges.flat_map { |e| [e[1], e[3]] }
            @empty = ys.empty?
            return if @empty

            @y_min, @y_max = ys.minmax
            @band = (@y_max - @y_min) / BANDS
            @buckets = Array.new(BANDS + 1) { [] }
            @edges.each do |edge|
              low, high = [edge[1], edge[3]].minmax
              (bucket_for(low)..bucket_for(high)).each { |b| @buckets[b] << edge }
            end
          end

          def spans_at(y)
            return [] if @empty || y < @y_min || y > @y_max

            PolygonArea.spans_at(@buckets[bucket_for(y)], y)
          end

          private

          def bucket_for(y)
            return 0 if @band.nil? || @band <= 0

            (((y - @y_min) / @band).floor).clamp(0, BANDS)
          end
        end
      end
    end
  end
end

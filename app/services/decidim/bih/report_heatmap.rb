# frozen_string_literal: true

module Decidim
  module Bih
    # Aggregates citizen problem reports into a per-Mjesna zajednica (MZ),
    # per-AI-category community signal — the data behind the public + admin
    # problem heatmap ("ovog mjeseca: 40% putevi u MZ Centar").
    #
    # PII-SAFE BY CONSTRUCTION: the query selects ONLY mz_slug, category,
    # severity and a count. Descriptions, contacts, coordinates, addresses and
    # references never leave the database. The returned structs expose counts and
    # the MZ identity (slug + display name) and nothing else.
    #
    # Scope rules:
    #   - org-scoped (decidim_organization_id),
    #   - reports with a nil mz_slug are excluded (no community signal),
    #   - reports created before `since` are excluded (default: last 90 days),
    #   - the MZ display name is resolved via LocalArea for the current locale.
    #
    # Usage:
    #   result = Decidim::Bih::ReportHeatmap.new(organization: org).call
    #   result.total                 # => Integer (reports counted)
    #   result.categories            # => ["putevi", "rasvjeta", ...] (sorted)
    #   result.areas                 # => [Area, ...] ordered by total desc
    #   area.mz_slug / area.mz_name  # MZ identity
    #   area.total                   # reports in this MZ in-window
    #   area.category_counts["putevi"] / area.severity_counts["hitan"]
    #   area.top_category            # => "putevi" (or nil)
    #   area.top_category_share      # => 0.4 (fraction; nil when total.zero?)
    class ReportHeatmap
      DEFAULT_WINDOW = 90

      # A single MZ's aggregated, PII-free counts. Exposes counts + MZ identity
      # ONLY — deliberately no report attributes (see the test that asserts the
      # struct does not respond to description/contact/coordinate accessors).
      class Area
        attr_reader :mz_slug, :mz_name, :total, :category_counts, :severity_counts

        def initialize(mz_slug:, mz_name:, total:, category_counts:, severity_counts:)
          @mz_slug = mz_slug
          @mz_name = mz_name
          @total = total
          @category_counts = category_counts
          @severity_counts = severity_counts
        end

        # The most frequent category in this MZ (nil when there are no reports).
        def top_category
          category_counts.max_by { |_cat, count| count }&.first
        end

        # The share (0.0–1.0) the top category represents — drives the
        # "40% putevi u MZ Centar" headline. nil when there is no data.
        def top_category_share
          return nil if total.to_i.zero?

          top = category_counts.values.max
          return nil if top.nil?

          top.to_f / total
        end
      end

      # Aggregate result for the whole organisation in-window.
      class Result
        attr_reader :areas, :categories, :total, :since

        def initialize(areas:, categories:, total:, since:)
          @areas = areas
          @categories = categories
          @total = total
          @since = since
        end
      end

      def initialize(organization:, since: nil)
        @organization = organization
        @since = since || DEFAULT_WINDOW.days.ago
      end

      def call
        rows = grouped_counts
        slugs = rows.keys.map(&:first).uniq
        names = mz_names_for(slugs)

        areas = build_areas(rows, names)
                .sort_by { |area| [-area.total, area.mz_slug] }

        Result.new(
          areas:,
          categories: rows.keys.map { |(_slug, category, _severity)| category }.compact.uniq.sort,
          total: areas.sum(&:total),
          since:
        )
      end

      private

      attr_reader :organization, :since

      # GROUP BY (mz_slug, category, severity) → count. The select list is the
      # whole privacy guarantee: nothing but the four count dimensions.
      def grouped_counts
        Decidim::Bih::Report
          .where(organization:)
          .publicly_visible
          .where.not(mz_slug: nil)
          .where(created_at: since..)
          .group(:mz_slug, :category, :severity)
          .count
      end

      def build_areas(rows, names)
        by_slug = rows.group_by { |(slug, _category, _severity), _count| slug }

        by_slug.map do |slug, entries|
          category_counts = Hash.new(0)
          severity_counts = Hash.new(0)
          total = 0

          entries.each do |(_slug, category, severity), count|
            total += count
            category_counts[category] += count if category.present?
            severity_counts[severity] += count if severity.present?
          end

          Area.new(
            mz_slug: slug,
            mz_name: names[slug] || slug,
            total:,
            category_counts:,
            severity_counts:
          )
        end
      end

      # Resolve each MZ slug to its localised display name in one query.
      def mz_names_for(slugs)
        return {} if slugs.empty?

        Decidim::Bih::LocalArea
          .mz
          .where(decidim_organization_id: organization.id, slug: slugs)
          .each_with_object({}) { |mz, acc| acc[mz.slug] = mz.translated_name }
      end
    end
  end
end

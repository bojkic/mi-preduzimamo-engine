# frozen_string_literal: true

module Decidim
  module Bih
    # A geographic boundary record representing either a Mjesna zajednica (MZ, kind="mz")
    # or a Komšiluk (kind="komsiluk"). The two kinds are INDEPENDENT — a komšiluk
    # is NOT a child of an MZ. Komšiluci cross MZ borders by design (MZ borders run
    # down street centerlines; a komšiluk covers both sides of a street).
    #
    # MZ→komšiluk relations are computed from geometry and stored as slugs:
    #   primary_mz_slug      — MZ holding the largest share of this komšiluk's area
    #   overlapping_mz_slugs — every MZ the komšiluk intersects
    # Run `rake decidim_bih:geo:compute_relations[org_host]` after importing areas.
    #
    # The `boundary` column stores a GeoJSON Polygon or MultiPolygon as plain jsonb.
    # Point-in-polygon queries are done in Ruby by Decidim::Bih::Geo::AreaLocator.
    #
    # Reference data is operator-supplied via the rake task:
    #   rake decidim_bih:geo:import_areas[path,org_host]
    class LocalArea < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_local_areas"

      KINDS = %w(mz komsiluk).freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      # Self-referential parent — retained for backward-compatibility but no
      # longer required or populated. Komšiluci are decoupled from MZ; use
      # primary_mz_slug / overlapping_mz_slugs for the soft relation instead.
      belongs_to :parent,
                 class_name: "Decidim::Bih::LocalArea",
                 optional: true

      has_many :children,
               class_name: "Decidim::Bih::LocalArea",
               foreign_key: :parent_id,
               dependent: :destroy,
               inverse_of: :parent

      validates :kind, presence: true, inclusion: { in: KINDS }
      validates :slug, presence: true
      validates :name, presence: true

      # Race league. A komšiluk is "grad" when the MAJORITY OF ITS AREA falls
      # inside the Bijeljina settlement frame, "selo" otherwise — computed once
      # by Decidim::Bih::Geo::ZoneClassifier and then locked for the race.
      # Deliberately NOT derived from the name and NOT from the centroid: an
      # elongated komšiluk on the city edge can have its centroid on the wrong side.
      ZONES = %w(grad selo).freeze

      validates :zona, allow_nil: true, inclusion: { in: ZONES }

      scope :mz, -> { where(kind: "mz") }
      scope :komsiluci, -> { where(kind: "komsiluk") }
      scope :grad, -> { where(zona: "grad") }
      scope :selo, -> { where(zona: "selo") }

      # Returns the localised name for the current I18n.locale, rendered in the
      # active locale's SCRIPT. Reference names are imported from GeoJSON in
      # Cyrillic and stored that way across all locale keys, which mismatches the
      # Latin locales (sr/bs/hr) — so we transliterate to match: Latin for
      # sr/bs/hr/en, Cyrillic for sr-Cyrl. The stored DB value is never mutated;
      # this is a display-time conversion (Decidim::Bih::Transliterator#localize
      # detects the source script and is idempotent when already correct).
      def translated_name
        locale_key = I18n.locale.to_s
        raw = name[locale_key] ||
              name[locale_key.split("-").first] ||
              name.values.compact.first ||
              slug
        Decidim::Bih::Transliterator.localize(raw, locale: locale_key)
      end

      # The MZ council president's name rendered in the active locale's script.
      # `predsjednik` is a plain (non-translatable) column imported in Cyrillic;
      # like #translated_name it is transliterated for display only, never in DB.
      # Returns nil/blank unchanged so view `present?` guards still work.
      def display_predsjednik
        Decidim::Bih::Transliterator.localize(predsjednik, locale: I18n.locale.to_s)
      end

      # The MZ holding the largest share of this komšiluk's area (soft pointer,
      # computed by RelationsComputer). Returns the LocalArea or nil.
      def primary_mz
        return nil if primary_mz_slug.blank?

        self.class.mz.find_by(
          decidim_organization_id:,
          slug: primary_mz_slug
        )
      end

      # Every MZ this komšiluk intersects (computed by RelationsComputer).
      # Returns an ActiveRecord::Relation ordered by slug.
      def overlapping_mz
        slugs = overlapping_mz_slugs.presence || []
        return self.class.none if slugs.empty?

        self.class.mz.where(decidim_organization_id:, slug: slugs).order(:slug)
      end
    end
  end
end

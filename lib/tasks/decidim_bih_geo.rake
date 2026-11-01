# frozen_string_literal: true

require "json"

namespace :decidim_bih do
  namespace :geo do
    desc <<~DESC
      Import or update local areas (MZ + Komšiluci) from a GeoJSON FeatureCollection.
      Usage: rake "decidim_bih:geo:import_areas[path/to/file.geojson,org.host.com]"

      The task branches on the GeoJSON feature's `kind` property:

      ── MZ features (kind="mz") ──────────────────────────────────────────────────
      Required properties:
        kind       String  "mz"
        slug       String  URL-safe identifier unique within the org
        name       Object  Locale hash: {"sr":"...", "bs":"...", "hr":"...", "en":"..."}

      Optional properties (written to MZ columns if present):
        predsjednik    String  Name of the MZ council president
        telefon        String  MZ council contact phone
        povrsina_m2    Number  \
        obim_m         Number   Stored together in the `metadata` jsonb column
        naziv_gis      String  /
        izvor          String  /

      ── Komšiluk features (kind="komsiluk") ──────────────────────────────────────
      Required properties:
        kind   String  "komsiluk"
        id     Integer  Unique integer identifier (used to auto-generate slug when
                         `naziv` is absent: "komsiluk-<id>")
        naziv  String   Neighbourhood name. May be empty/absent — slug falls back to
                         "komsiluk-<id>". name is set to all-locale copy of naziv (or slug).

      Optional properties:
        slug   String   Stable identifier. When present it takes precedence over a
                        slug derived from `naziv`; use this when display names may change.

      Komšiluci are NOT linked to a parent MZ (decoupled model). Relations are
      computed separately via: rake decidim_bih:geo:compute_relations[org.host.com]

      ── General ───────────────────────────────────────────────────────────────────
      The task is IDEMPOTENT: re-running upserts by slug (updates in place; no
      duplicates). MZ features are processed before komšiluk features regardless
      of order in the file.

      Pre-computed centroid:
        centroid_lat  Float  (overrides auto-compute)
        centroid_lon  Float  (overrides auto-compute)
    DESC
    task :import_areas, [:path, :org_host] => :environment do |_task, args|
      path = args[:path]
      org_host = args[:org_host]

      abort "Usage: rake \"decidim_bih:geo:import_areas[path,org_host]\"" if path.blank? || org_host.blank?
      abort "File not found: #{path}" unless File.exist?(path)

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      collection = begin
        JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        abort "Invalid JSON: #{e.message}"
      end

      abort "Expected a GeoJSON FeatureCollection at the top level." unless collection.is_a?(Hash) && collection["type"] == "FeatureCollection"

      features = collection["features"] || []
      imported = 0
      updated = 0
      errors = 0
      # Track whether any MZ boundary was created or re-shaped this import. A
      # re-shaped MZ silently invalidates the computed primary/overlapping
      # relations of every komšiluk that used to overlap it, so we must
      # recompute relations as a final step (see below).
      mz_boundary_changed = false
      komsiluk_boundary_changed = false

      # Two-pass: MZ first (komšiluk import is independent but order is kept
      # consistent for predictable output).
      mz_features = features.select { |f| f.dig("properties", "kind") == "mz" }
      komsiluk_features = features.select { |f| f.dig("properties", "kind") == "komsiluk" }
      other_features = features.reject { |f| %w(mz komsiluk).include?(f.dig("properties", "kind")) }

      warn "Skipping #{other_features.size} feature(s) with unrecognised kind." if other_features.any?

      # ── MZ import ─────────────────────────────────────────────────────────────
      mz_features.each do |feature|
        props = feature["properties"] || {}
        slug = props["slug"].presence
        kind = "mz"
        raw_name = props["name"]

        unless slug
          warn "Skipping MZ feature without slug: #{props.inspect}"
          errors += 1
          next
        end

        name = case raw_name
               when String then { "sr" => raw_name, "bs" => raw_name, "hr" => raw_name, "en" => raw_name }
               when Hash then raw_name
               else
                 warn "Skipping #{slug}: name must be a string or locale hash."
                 errors += 1
                 next
               end

        geometry = feature["geometry"]
        centroid = compute_centroid(geometry)
        centroid_lat = props["centroid_lat"]&.to_f || centroid&.first
        centroid_lon = props["centroid_lon"]&.to_f || centroid&.last

        # Stash GIS export fields in metadata
        metadata = {}
        %w(povrsina_m2 obim_m naziv_gis izvor).each do |key|
          metadata[key] = props[key] if props.has_key?(key)
        end

        area = Decidim::Bih::LocalArea.find_or_initialize_by(
          decidim_organization_id: organization.id,
          slug:
        )
        new_record = area.new_record?

        attrs = {
          kind:,
          name:,
          boundary: geometry,
          centroid_lat:,
          centroid_lon:,
          organization:,
          # Merge (don't replace): a re-import that carries some GIS keys must
          # not drop other metadata keys an earlier import / operator set.
          metadata: (area.metadata || {}).merge(metadata)
        }
        attrs[:predsjednik] = props["predsjednik"] if props.has_key?("predsjednik")
        attrs[:telefon] = props["telefon"] if props.has_key?("telefon")

        area.assign_attributes(attrs)

        # A new MZ (with a boundary) or a re-shaped existing MZ changes the
        # geographic overlap surface and must trigger a relations recompute.
        boundary_changed_now = area.boundary_changed?

        if area.save
          mz_boundary_changed ||= boundary_changed_now
          new_record ? (imported += 1) : (updated += 1)
        else
          warn "Failed to save MZ #{slug}: #{area.errors.full_messages.join(", ")}"
          errors += 1
        end
      rescue StandardError => e
        warn "Error processing MZ feature #{props.inspect}: #{e.class}: #{e.message}"
        errors += 1
      end

      # ── Komšiluk import ───────────────────────────────────────────────────────
      komsiluk_features.each do |feature|
        props = feature["properties"] || {}
        kind = "komsiluk"

        # Prefer an explicit stable slug. Otherwise slugify naziv if present, then
        # fall back to "komsiluk-<id>". Keeping identity separate from display
        # copy lets an operator rename a provisional area without creating a new row.
        naziv = props["naziv"].to_s.strip
        feature_id = props["id"]
        explicit_slug = props["slug"].to_s.strip

        slug = if explicit_slug.present?
                 slugify(explicit_slug)
               elsif naziv.present?
                 slugify(naziv)
               elsif feature_id.present?
                 "komsiluk-#{feature_id}"
               else
                 warn "Skipping komsiluk feature without id or naziv: #{props.inspect}"
                 errors += 1
                 next
               end

        # Name: all locales set to naziv (or slug as fallback)
        display_name = naziv.presence || slug
        name = { "sr" => display_name, "bs" => display_name, "hr" => display_name, "en" => display_name }

        geometry = feature["geometry"]
        centroid = compute_centroid(geometry)
        centroid_lat = props["centroid_lat"]&.to_f || centroid&.first
        centroid_lon = props["centroid_lon"]&.to_f || centroid&.last

        area = Decidim::Bih::LocalArea.find_or_initialize_by(
          decidim_organization_id: organization.id,
          slug:
        )
        new_record = area.new_record?

        # Decoupled model: do NOT set parent. MZ relations are computed separately.
        area.assign_attributes(
          kind:,
          name:,
          boundary: geometry,
          centroid_lat:,
          centroid_lon:,
          organization:,
          parent: nil
        )

        # Capture before save (save clears dirty tracking). A new komšiluk has no
        # relations yet, and a re-shaped one's relations are now stale — both need
        # a recompute. boundary_changed? is true for new records (all attrs dirty).
        komsiluk_changed_now = area.boundary_changed?

        # If an existing komšiluk's geometry changed, its computed MZ relations
        # are now stale — clear them so a re-shaped boundary never serves a wrong
        # primary/overlapping MZ until relations are recomputed below.
        if !new_record && komsiluk_changed_now
          area.primary_mz_slug = nil
          area.overlapping_mz_slugs = []
        end

        if area.save
          new_record ? (imported += 1) : (updated += 1)
          komsiluk_boundary_changed ||= komsiluk_changed_now
        else
          warn "Failed to save komsiluk #{slug}: #{area.errors.full_messages.join(", ")}"
          errors += 1
        end
      rescue StandardError => e
        warn "Error processing komsiluk feature #{props.inspect}: #{e.class}: #{e.message}"
        errors += 1
      end

      # If any MZ boundary OR komšiluk boundary was created/re-shaped, the computed
      # primary/overlapping MZ relations may now be stale (a reshaped MZ invalidates
      # every overlapping komšiluk; a new/reshaped komšiluk needs its own relations).
      # RelationsComputer#compute! is idempotent, so recompute as a final step —
      # this keeps MZ-president routing and MZ fallback correct without operator
      # intervention.
      if mz_boundary_changed || komsiluk_boundary_changed
        result = Decidim::Bih::Geo::RelationsComputer.new(organization).compute!
        puts "Boundaries changed — recomputed relations: #{result[:updated]} komšiluci updated (#{result[:skipped]} skipped)."
      end

      puts "Import complete: #{imported} created, #{updated} updated, #{errors} error(s)."
    end

    desc <<~DESC
      Compute MZ relations for all komšiluci in the given organisation and persist them.
      Usage: rake "decidim_bih:geo:compute_relations[org.host.com]"

      For each komšiluk, estimates MZ overlap by grid-sampling points across the
      komšiluk's bounding box. Pure-Ruby AreaLocator scanlines classify the grid;
      disjoint MZ bounding boxes are rejected before polygon work. The MZ receiving
      the most in-komšiluk hits becomes primary_mz_slug; thresholded hit MZs go into
      overlapping_mz_slugs.

      This supersedes the brief's compute_komsiluk_mz_relations.py Python/shapely
      script — same algorithm, zero external dependencies, reuses AreaLocator's
      geometry code.

      The task is idempotent and re-runnable after each re-import.
    DESC
    task :compute_relations, [:org_host] => :environment do |_task, args|
      org_host = args[:org_host]
      abort "Usage: rake \"decidim_bih:geo:compute_relations[org_host]\"" if org_host.blank?

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      computer = Decidim::Bih::Geo::RelationsComputer.new(organization)
      result = computer.compute!

      puts "Relations computed: #{result[:updated]} komšiluci updated (#{result[:skipped]} skipped — no boundary)."
    end

    desc <<~DESC
      Validate the geo reference data for silent routing-data corruption (read-only).
      Usage: rake "decidim_bih:geo:validate[org.host.com]"

      A health check to run BEFORE and AFTER each import_areas run. It changes
      no data; it only reports issues, grouped by class:

        empty_overlaps          komšiluci with empty overlapping_mz_slugs
                                (relations likely never computed)
        degenerate_boundary     areas with a nil/degenerate boundary
                                (no representative point — can't be located/mapped)
        dangling_primary_mz     komšiluci whose primary_mz_slug points at a
                                non-existent MZ
        point_outside_boundary  areas whose stored centroid is outside their own
                                boundary (stale after an MZ re-import)

      Prints a count and the offending slugs per class, and a clear "✓ no issues"
      line when the data is clean.
    DESC
    task :validate, [:org_host] => :environment do |_task, args|
      org_host = args[:org_host]
      abort "Usage: rake \"decidim_bih:geo:validate[org_host]\"" if org_host.blank?

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      issues = Decidim::Bih::Geo::IntegrityCheck.new(organization).call
      total = issues.values.sum(&:size)

      labels = {
        empty_overlaps: "Komšiluci with EMPTY overlapping_mz_slugs (run compute_relations)",
        degenerate_boundary: "Areas with a NIL/DEGENERATE boundary",
        dangling_primary_mz: "Komšiluci whose primary_mz_slug points at a NON-EXISTENT MZ",
        point_outside_boundary: "Areas whose stored centroid is OUTSIDE its own boundary (stale)"
      }

      puts "Geo integrity check for #{org_host}:"
      puts "=" * 60

      if total.zero?
        puts "✓ no issues — geo reference data is clean."
        next
      end

      Decidim::Bih::Geo::IntegrityCheck::ISSUE_TYPES.each do |type|
        list = issues[type]
        puts
        puts "#{labels[type]}: #{list.size}"
        list.each do |entry|
          puts "  - #{entry[:slug]} (#{entry[:kind]}): #{entry[:message]}"
        end
      end

      puts
      puts "=" * 60
      puts "Total issues: #{total}"
    end

    desc <<~DESC
      Import the city-zone frame polygon used to split komšiluci into grad/selo.
      Usage: rake "decidim_bih:geo:import_city_frame[docs/handoff_decidim/frame_bijeljina.json,org.host.com]"

      Accepts a GeoJSON FeatureCollection (the first feature's geometry is used),
      a Feature, or a bare Polygon/MultiPolygon. Stored in Decidim::Bih::Setting
      under namespace "geo", key "city_frame" — the frame is DATA, not a path in code.
    DESC
    task :import_city_frame, [:path, :org_host] => :environment do |_task, args|
      path = args[:path]
      org_host = args[:org_host]
      abort "Usage: rake \"decidim_bih:geo:import_city_frame[path,org_host]\"" if path.blank? || org_host.blank?
      abort "File not found: #{path}" unless File.exist?(path)

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      parsed = JSON.parse(File.read(path))
      geometry =
        case parsed["type"]
        when "FeatureCollection" then parsed.dig("features", 0, "geometry")
        when "Feature" then parsed["geometry"]
        else parsed
        end
      abort "No Polygon/MultiPolygon geometry found in #{path}" if geometry.blank?
      abort "City frame must be a Polygon or MultiPolygon, got: #{geometry["type"].inspect}" unless %w(Polygon MultiPolygon).include?(geometry["type"])

      Decidim::Bih::Setting.put(organization, "geo", "city_frame", geometry)
      puts "Imported city frame (#{geometry["type"]}) for #{org_host}."
    end

    desc <<~DESC
      Classify komšiluci into grad/selo by share of area inside the city frame.
      Usage: rake "decidim_bih:geo:classify_zones[org.host.com]"        # DRY RUN, prints only
             rake "decidim_bih:geo:classify_zones[org.host.com,apply]"  # writes LocalArea#zona
             rake "decidim_bih:geo:classify_zones[org.host.com,force]"  # writes even when locked

      DRY RUN IS THE DEFAULT. The split decides who competes for 3.000 KM, so the
      printed report (including the 40–60% borderline cases) goes to the client for
      confirmation before anything is written or the race rules are published.
    DESC
    task :classify_zones, [:org_host, :mode] => :environment do |_task, args|
      org_host = args[:org_host]
      mode = args[:mode].to_s
      abort "Usage: rake \"decidim_bih:geo:classify_zones[org_host,apply]\"" if org_host.blank?

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      classifier = Decidim::Bih::Geo::ZoneClassifier.new(organization)
      results =
        begin
          if Decidim::Bih::Geo::ZoneModes.write?(mode)
            classifier.apply!(force: Decidim::Bih::Geo::ZoneModes.force?(mode))
          else
            classifier.classify
          end
        rescue Decidim::Bih::Geo::ZoneClassifier::MissingCityFrameError
          abort "No city frame stored. Run decidim_bih:geo:import_city_frame first."
        rescue Decidim::Bih::Geo::ZoneClassifier::ZonesLockedError
          abort "Zones are locked. Re-run with mode 'force' only if the client re-confirmed the split."
        end

      puts Decidim::Bih::Geo::ZoneReport.render(results)
      puts ""
      puts(Decidim::Bih::Geo::ZoneModes.write?(mode) ? "WRITTEN to LocalArea#zona." : "DRY RUN — nothing written. Re-run with ,apply to write.")
    end

    desc <<~DESC
      Lock the grad/selo split so it cannot change during the race.
      Usage: rake "decidim_bih:geo:lock_zones[org.host.com]"
    DESC
    task :lock_zones, [:org_host] => :environment do |_task, args|
      org_host = args[:org_host]
      abort "Usage: rake \"decidim_bih:geo:lock_zones[org_host]\"" if org_host.blank?

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      unassigned = Decidim::Bih::LocalArea.komsiluci.where(organization:, zona: nil).count
      abort "#{unassigned} komšiluk(a) still have no zona. Run classify_zones[...,apply] first." if unassigned.positive?

      locked_at = Decidim::Bih::Geo::ZoneClassifier.new(organization).lock!
      puts "Zones locked at #{locked_at}."
    end

    private

    # Guaranteed-interior representative point [lat, lon] for the geometry
    # (PostGIS ST_PointOnSurface-style) so concave/crescent MZ centre correctly.
    # Delegates to the engine so the same logic is unit-tested and reusable.
    def compute_centroid(geometry)
      Decidim::Bih::Geo::AreaLocator.representative_point(geometry)
    end

    # Convert a UTF-8 string into a URL-safe slug.
    # Delegates to the shared Slugifier service so the GeoJSON importer and the
    # non-polygon flat importer generate identical slugs for the same name.
    def slugify(str)
      Decidim::Bih::Geo::Slugifier.call(str)
    end
  end
end

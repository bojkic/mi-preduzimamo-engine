# frozen_string_literal: true

require "json"

namespace :decidim_bih do
  namespace :komsiluk do
    desc <<~DESC
      Import komšiluk LocalAreas from a SIMPLE FLAT LIST — NO boundary geometry.
      Usage: rake "decidim_bih:komsiluk:import_flat[path/to/list.txt,org.host.com]"

      This is the NON-POLYGON fallback: it lets operators stand up komšiluci so
      citizens can join one via the dropdown picker (which stores only komsiluk_id)
      BEFORE the real GeoJSON polygons (komsiluci_poligoni.geojson) arrive. Map /
      address pickers cannot place a boundary-less komšiluk — that is expected;
      only the dropdown path is unblocked here.

      Two input formats, auto-detected by content (a leading "[" → JSON):

      ── Plain text (one komšiluk per line) ───────────────────────────────────────
          Centar Sjever
          Galac | mz-centar          # optional primary MZ slug after a pipe
          # lines starting with # and blank lines are ignored

      ── JSON array ───────────────────────────────────────────────────────────────
          ["Centar Sjever", "Galac"]
        or
          [
            { "name": "Centar Sjever", "primary_mz_slug": "mz-centar" },
            { "name": "Galac", "slug": "galac-custom" }
          ]

      Per entry:
        name             required  display name (all four locales + en copy it)
        primary_mz_slug  optional  soft pointer to an existing MZ (used by the
                                   dropdown picker to resolve mz when no point is
                                   available). NOT validated against the MZ set.
        slug             optional  explicit slug override (default: slugified name)

      The task is IDEMPOTENT: re-running upserts by slug (updates name +
      primary_mz_slug in place; no duplicates). An existing `boundary` is NEVER
      touched, so a later real GeoJSON import is preserved across flat re-runs.
    DESC
    task :import_flat, [:path, :org_host] => :environment do |_task, args|
      path = args[:path]
      org_host = args[:org_host]

      abort "Usage: rake \"decidim_bih:komsiluk:import_flat[path,org_host]\"" if path.blank? || org_host.blank?
      abort "File not found: #{path}" unless File.exist?(path)

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      raw = File.read(path)
      entries = parse_flat_komsiluci(raw)
      abort "No komšiluci found in #{path}." if entries.empty?

      imported = 0
      updated = 0
      errors = 0

      entries.each do |entry|
        # Collapse interior whitespace runs so "Centar  Sjever" → "Centar Sjever"
        # (keeps the display name tidy and stable across re-imports).
        name = entry[:name].to_s.strip.gsub(/\s+/, " ")
        if name.blank?
          warn "Skipping entry without a name: #{entry.inspect}"
          errors += 1
          next
        end

        slug = entry[:slug].presence || Decidim::Bih::Geo::Slugifier.call(name)
        display = { "sr" => name, "bs" => name, "hr" => name, "en" => name }

        area = Decidim::Bih::LocalArea.find_or_initialize_by(
          decidim_organization_id: organization.id,
          slug:
        )
        new_record = area.new_record?

        attrs = {
          kind: "komsiluk",
          name: display,
          organization:,
          parent: nil
        }
        # Only set the soft pointer when explicitly supplied; never clobber an
        # existing computed primary_mz_slug with nil on a bare re-run.
        attrs[:primary_mz_slug] = entry[:primary_mz_slug] if entry.has_key?(:primary_mz_slug) && entry[:primary_mz_slug].present?

        area.assign_attributes(attrs)
        # NOTE: boundary is intentionally never assigned — flat komšiluci have no
        # geometry, and a later real GeoJSON import must survive a flat re-run.

        if area.save
          new_record ? (imported += 1) : (updated += 1)
        else
          warn "Failed to save komsiluk #{slug}: #{area.errors.full_messages.join(", ")}"
          errors += 1
        end
      rescue StandardError => e
        warn "Error processing entry #{entry.inspect}: #{e.class}: #{e.message}"
        errors += 1
      end

      puts "Flat import complete: #{imported} created, #{updated} updated, #{errors} error(s)."
    end

    desc "Expire open Komšiluk board posts whose expires_at is in the past " \
         "(dry-run unless APPLY=1). Set ORGANIZATION_ID or HOST to select the org."
    task expire_posts: :environment do
      organization = find_komsiluk_organization
      abort "Set ORGANIZATION_ID or HOST" unless organization

      scope = Decidim::Bih::KomsilukPost
              .where(decidim_organization_id: organization.id)
              .where(status: "open")
              .where("expires_at IS NOT NULL AND expires_at < ?", Time.current)

      count = scope.count

      puts "organization=#{organization.id} host=#{organization.host}"
      puts "dry_run=#{ENV["APPLY"] != "1"}"
      puts "posts_to_expire=#{count}"

      if ENV["APPLY"] == "1"
        expired = 0
        scope.find_each do |post|
          post.with_lock do
            next unless post.open? && post.expires_at && post.expires_at < Time.current

            post.update!(status: "expired")
            Decidim::Bih::Komsiluk::NoticePublishing.cancel_pending_for!(post:, reason: "expired")
            expired += 1
          end
        end
        source_provider = Decidim::Bih::Komsiluk::NoticeComposer.source_provider
        source_provider.refresh_due!(organization:) if source_provider.respond_to?(:refresh_due!)
        Decidim::Bih::KomsilukPhotoDraft.where(organization:).where(expires_at: ..Time.current).find_each(&:expire!)
        puts "Expired #{expired} posts."
      else
        puts "No changes were made. Set APPLY=1 to expire these posts."
      end
    end
  end
end

def find_komsiluk_organization
  if ENV["ORGANIZATION_ID"].present?
    Decidim::Organization.find_by(id: ENV["ORGANIZATION_ID"])
  elsif ENV["HOST"].present?
    Decidim::Organization.find_by(host: ENV["HOST"])
  end
end

# Parse a flat komšiluk source string into an array of normalised hashes:
#   { name:, primary_mz_slug? , slug? }
# Auto-detects JSON (content starts with "[") vs the one-per-line text format.
def parse_flat_komsiluci(raw)
  if raw.strip.start_with?("[")
    parse_flat_komsiluci_json(raw)
  else
    parse_flat_komsiluci_text(raw)
  end
end

def parse_flat_komsiluci_json(raw)
  parsed = JSON.parse(raw)
  abort "Expected a JSON array of strings or objects." unless parsed.is_a?(Array)

  parsed.filter_map do |item|
    case item
    when String
      { name: item.strip }
    when Hash
      entry = { name: item["name"].to_s.strip }
      entry[:slug] = item["slug"].to_s.strip if item.has_key?("slug")
      entry[:primary_mz_slug] = item["primary_mz_slug"].to_s.strip if item.has_key?("primary_mz_slug")
      entry
    end
  end
rescue JSON::ParserError => e
  abort "Invalid JSON: #{e.message}"
end

# One komšiluk per line. Blank lines and lines starting with "#" are ignored.
# An optional primary MZ slug may follow a pipe: "Naziv | mz-slug".
def parse_flat_komsiluci_text(raw)
  raw.each_line.filter_map do |line|
    line = line.strip
    next if line.blank? || line.start_with?("#")

    name, primary_mz_slug = line.split("|", 2).map(&:strip)
    entry = { name: }
    entry[:primary_mz_slug] = primary_mz_slug if primary_mz_slug.present?
    entry
  end
end

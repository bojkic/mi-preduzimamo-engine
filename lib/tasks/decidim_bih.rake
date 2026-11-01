# frozen_string_literal: true

require "yaml"
require "json"
require "decidim/bih/transliterator"

namespace :decidim_bih do
  desc "Generate the Serbian Cyrillic locale (sr-Cyrl) from the Latin source (sr)"
  task :cyrillize do
    locales_dir = File.expand_path("../../config/locales", __dir__)
    source = File.join(locales_dir, "sr.yml")
    target = File.join(locales_dir, "sr-Cyrl.yml")

    raise "Source locale not found: #{source}" unless File.exist?(source)

    data = YAML.safe_load_file(source)
    raise "Expected top-level `sr:` key in #{source}" unless data.is_a?(Hash) && data.has_key?("sr")

    cyrillic = { "sr-Cyrl" => Decidim::Bih::Transliterator.deep(data.fetch("sr")) }

    header = <<~HEADER
      # Serbian (Cyrillic) — `sr-Cyrl`.
      #
      # AUTO-GENERATED from sr.yml by `rake decidim_bih:cyrillize`. DO NOT EDIT.
      # Edit the Latin source (sr.yml) and regenerate.
    HEADER

    File.write(target, header + YAML.dump(cyrillic, line_width: -1))
    # Optional supplements keep their maintained Latin source alongside other
    # locales. Never hand-edit their generated sr-Cyrl key.
    ENV.fetch("EXTRA_CYRILLIC_LOCALES", "").split(",").map(&:strip).reject(&:empty?).each do |path|
      supplement = YAML.safe_load_file(path, aliases: true)
      raise "Expected top-level sr key in #{path}" unless supplement.is_a?(Hash) && supplement.has_key?("sr")

      supplement["sr-Cyrl"] = Decidim::Bih::Transliterator.deep(supplement.fetch("sr"))
      File.write(path, YAML.dump(supplement, line_width: -1))
      puts "Generated sr-Cyrl in #{path}"
    end
    puts "Generated #{target} (#{Decidim::Bih::Transliterator.deep(data.fetch("sr")).inspect.length} chars of content)"
  end

  namespace :host_contract do
    desc "Print required public asset manifest as JSON"
    task :assets do
      require "decidim/bih"

      puts JSON.pretty_generate(Decidim::Bih.required_public_asset_manifest)
    end

    desc "Copy packaged public assets into PUBLIC_ROOT (default: Rails.root/public)"
    task :install_assets do
      require "decidim/bih"

      default_public_root = if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
                              Rails.public_path.to_s
                            else
                              File.expand_path("public", Dir.pwd)
                            end
      public_root = ENV.fetch("PUBLIC_ROOT", default_public_root)
      overwrite_value = ENV.fetch("OVERWRITE_ASSETS", ENV.fetch("OVERWRITE", "0"))
      overwrite = overwrite_value.match?(/\A(1|true|yes)\z/i)

      result = Decidim::Bih.install_required_public_assets!(public_root:, overwrite:)

      puts "public_root=#{result.fetch(:public_root)}"
      puts "source_root=#{result.fetch(:source_root)}"
      puts "copied=#{result.fetch(:copied).size}"
      puts "skipped=#{result.fetch(:skipped).size}"
    end

    desc "Print required public throttle manifest as JSON (PUBLIC_MOUNT_PATH=/moja-platforma SHORT_MAGIC_LINKS=1)"
    task :throttles do
      require "decidim/bih"

      short_magic_links = ENV.fetch(
        "SHORT_MAGIC_LINKS",
        ENV.fetch("DECIDIM_BIH_MAGIC_LINK_SHORT_PATH_ENABLED", Decidim::Bih.magic_link_short_path_enabled.to_s)
      )
      puts JSON.pretty_generate(
        Decidim::Bih.required_public_throttles_for_mount(
          mount_path: ENV.fetch("PUBLIC_MOUNT_PATH", Decidim::Bih.public_mount_path),
          short_magic_links:
        )
      )
    end

    desc "Print public write route classification manifest as JSON (PUBLIC_MOUNT_PATH=/moja-platforma)"
    task :public_writes do
      require "decidim/bih"

      puts JSON.pretty_generate(
        Decidim::Bih.required_public_write_routes_for_mount(
          mount_path: ENV.fetch("PUBLIC_MOUNT_PATH", Decidim::Bih.public_mount_path)
        )
      )
    end

    desc "Print public surface/product vocabulary review manifest as JSON (PUBLIC_MOUNT_PATH=/moja-platforma)"
    task :public_surfaces do
      require "decidim/bih"

      puts JSON.pretty_generate(
        Decidim::Bih.required_public_surfaces_for_mount(
          mount_path: ENV.fetch("PUBLIC_MOUNT_PATH", Decidim::Bih.public_mount_path)
        )
      )
    end

    desc "Print host provider interface contracts as JSON"
    task :providers do
      require "decidim/bih"

      puts JSON.pretty_generate(Decidim::Bih.required_provider_contracts)
    end

    desc "Print hard Decidim module dependency contract as JSON"
    task :decidim_modules do
      require "decidim/bih"

      puts JSON.pretty_generate(Decidim::Bih.required_decidim_modules)
    end

    desc "Print privacy, retention, audit and analytics contracts as JSON"
    task :privacy_audit do
      require "decidim/bih"

      puts JSON.pretty_generate(
        Decidim::Bih.privacy_audit_contract_manifest(
          mount_path: ENV.fetch("PUBLIC_MOUNT_PATH", Decidim::Bih.public_mount_path)
        )
      )
    end

    desc "Print full second-host contract manifest as JSON (PUBLIC_MOUNT_PATH=/moja-platforma SHORT_MAGIC_LINKS=1)"
    task :manifest do
      require "decidim/bih"

      short_magic_links = ENV.fetch(
        "SHORT_MAGIC_LINKS",
        ENV.fetch("DECIDIM_BIH_MAGIC_LINK_SHORT_PATH_ENABLED", Decidim::Bih.magic_link_short_path_enabled.to_s)
      )
      puts JSON.pretty_generate(
        Decidim::Bih.host_contract_manifest(
          mount_path: ENV.fetch("PUBLIC_MOUNT_PATH", Decidim::Bih.public_mount_path),
          short_magic_links:
        )
      )
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "decidim/bih"
require "fileutils"
require "tmpdir"

class PublicAssetsTest < Minitest::Test
  def test_required_public_assets_are_absolute_unique_and_sorted
    assets = Decidim::Bih.required_public_assets

    assert_equal assets.sort, assets
    assert_equal assets.uniq, assets
    assert(assets.all? { |asset| asset.start_with?("/") })
  end

  def test_required_public_assets_cover_engine_asset_families
    assets = Decidim::Bih.required_public_assets

    assert_includes assets, "/mi/mi-theme.css"
    assert_includes assets, "/mi/mi-chat-loader.js"
    assert_includes assets, "/mi/mi-bot.css"
    assert_includes assets, "/mi/bih-report-location-map.js"
    assert_includes assets, "/mi/bih-reports-map.js"
    assert_includes assets, "/mi/bih-komsiluk-map.js"
    assert_includes assets, "/mi/bih-mz-map.js"
    assert_includes assets, "/mi/heart-mark.png"
    assert_includes assets, "/leaflet/leaflet.css"
    assert_includes assets, "/leaflet/images/marker-icon-2x.png"
    assert_includes assets, "/mi/fonts/92zatBhPNqw73oTd4g.woff2"
    assert_includes assets, "/mi/stickers/prijavljeno.png"
    assert_includes assets, "/mi/stickers/bravo.png"
  end

  def test_required_public_asset_manifest_maps_public_to_relative_paths
    manifest = Decidim::Bih.required_public_asset_manifest
    theme = manifest.find { |asset| asset.fetch(:public_path) == "/mi/mi-theme.css" }

    assert_equal Decidim::Bih.required_public_assets.size, manifest.size
    assert_equal "mi/mi-theme.css", theme.fetch(:relative_path)
    assert(manifest.all? { |asset| asset.fetch(:public_path).start_with?("/") })
    assert(manifest.none? { |asset| asset.fetch(:relative_path).start_with?("/") })
  end

  def test_packaged_public_asset_sources_exist
    manifest = Decidim::Bih.required_public_asset_source_manifest

    assert_equal Decidim::Bih.required_public_assets.size, manifest.size
    assert manifest.all? { |asset| asset.fetch(:source_exists) },
           "Missing packaged assets: #{manifest.reject { |asset| asset.fetch(:source_exists) }.map { |asset| asset.fetch(:relative_path) }.join(", ")}"
    assert(manifest.all? { |asset| asset.fetch(:source_size_bytes).positive? })
  end

  def test_packaged_chat_asset_does_not_hardcode_default_mount_fallbacks
    script = File.read(Decidim::Bih.required_public_asset_source_path("mi/mi-chat.js"))

    refute_includes script, "/biceriseno/chat"
    refute_includes script, "/biceriseno/prijave/new"
    refute_includes script, "/biceriseno/donacije"
    assert_includes script, "CFG.endpoint"
    assert_includes script, "CFG.publicBasePath"
  end

  def test_packaged_public_js_fallback_copy_is_host_neutral
    chat = File.read(Decidim::Bih.required_public_asset_source_path("mi/mi-chat.js"))
    install = File.read(Decidim::Bih.required_public_asset_source_path("mi/mi-install.js"))

    refute_includes chat, "MI! bot"
    refute_includes install, "Instaliraj MI"
    refute_includes install, "Dodaj MI"
    assert_includes chat, "Platform assistant"
    assert_includes install, "aplikaciju platforme"
  end

  def test_packaged_public_maps_expose_recoverable_failure_states
    reports = File.read(Decidim::Bih.required_public_asset_source_path("mi/bih-reports-map.js"))
    komsiluk = File.read(Decidim::Bih.required_public_asset_source_path("mi/bih-komsiluk-map.js"))

    assert_includes reports, "statusUnavailable"
    assert_includes reports, "retryButtonId"
    assert_includes reports, "window.location.reload()"
    assert_includes komsiluk, "address-unavailable"
    assert_includes komsiluk, 'setStatus("unavailable"'
    refute_includes komsiluk, "Leave base map visible"
  end

  def test_packaged_chat_loader_supports_page_level_open_action
    loader = File.read(Decidim::Bih.required_public_asset_source_path("mi/mi-chat-loader.js"))

    assert_includes loader, "[data-mi-chat-open]"
  end

  def test_install_public_assets_copies_required_files_without_overwriting
    Dir.mktmpdir("decidim-bih-assets") do |public_root|
      result = Decidim::Bih.install_public_assets!(public_root:)
      theme_path = File.join(public_root, "mi/mi-theme.css")

      assert_equal Decidim::Bih.required_public_assets.size, result.fetch(:copied).size
      assert_equal [], result.fetch(:skipped)
      assert File.exist?(theme_path)

      File.write(theme_path, "host custom theme")
      result = Decidim::Bih.install_public_assets!(public_root:)

      assert_equal "host custom theme", File.read(theme_path)
      assert_includes result.fetch(:skipped), "mi/mi-theme.css"
    end
  end

  def test_install_public_assets_can_overwrite_existing_files
    Dir.mktmpdir("decidim-bih-assets") do |public_root|
      theme_path = File.join(public_root, "mi/mi-theme.css")
      FileUtils.mkdir_p(File.dirname(theme_path))
      File.write(theme_path, "host custom theme")

      result = Decidim::Bih.install_public_assets!(public_root:, overwrite: true)

      assert_includes result.fetch(:copied), "mi/mi-theme.css"
      refute_equal "host custom theme", File.read(theme_path)
    end
  end

  def test_install_public_assets_rejects_missing_source_root
    Dir.mktmpdir("decidim-bih-assets") do |public_root|
      error = assert_raises(RuntimeError) do
        Decidim::Bih.install_public_assets!(public_root:, source_root: File.join(public_root, "missing"))
      end

      assert_includes error.message, "Missing packaged public assets"
    end
  end
end

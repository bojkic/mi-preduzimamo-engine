# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "rake"
require "tmpdir"

class DecidimBihHostContractTasksTest < Minitest::Test
  def setup
    @rake = Rake::Application.new
    @original_rake = Rake.application
    Rake.application = @rake
    load File.expand_path("../../lib/tasks/decidim_bih.rake", __dir__)
  end

  def teardown
    Rake.application = @original_rake
  end

  def test_install_assets_task_copies_packaged_assets_to_public_root
    Dir.mktmpdir("decidim-bih-assets") do |public_root|
      with_env("PUBLIC_ROOT" => public_root) do
        @rake["decidim_bih:host_contract:install_assets"].invoke
      end

      assert File.exist?(File.join(public_root, "mi/mi-theme.css"))
      assert File.exist?(File.join(public_root, "mi/stickers/prijavljeno.png"))
      assert File.exist?(File.join(public_root, "leaflet/leaflet.css"))
    end
  end

  def test_install_assets_task_supports_overwrite_alias
    Dir.mktmpdir("decidim-bih-assets") do |public_root|
      theme_path = File.join(public_root, "mi/mi-theme.css")
      FileUtils.mkdir_p(File.dirname(theme_path))
      File.write(theme_path, "host custom theme")

      with_env("PUBLIC_ROOT" => public_root, "OVERWRITE" => "1") do
        @rake["decidim_bih:host_contract:install_assets"].invoke
      end

      refute_equal "host custom theme", File.read(theme_path)
    end
  end

  def test_manifest_task_honors_short_magic_links_flag
    with_env("PUBLIC_MOUNT_PATH" => "/moja-platforma", "SHORT_MAGIC_LINKS" => "0") do
      stdout, = capture_io do
        @rake["decidim_bih:host_contract:manifest"].invoke
      end
      manifest = JSON.parse(stdout)
      magic_link = manifest.fetch("required_public_throttles").find { |throttle| throttle.fetch("id") == "magic_links.consume" }

      assert_equal false, manifest.fetch("magic_link_short_path_enabled")
      assert_equal ["/moja-platforma/v/:token"], magic_link.fetch("paths")
    end
  end

  def test_throttles_task_defaults_to_short_magic_link_route
    with_env("PUBLIC_MOUNT_PATH" => "/moja-platforma",
             "SHORT_MAGIC_LINKS" => nil,
             "DECIDIM_BIH_MAGIC_LINK_SHORT_PATH_ENABLED" => nil) do
      stdout, = capture_io do
        @rake["decidim_bih:host_contract:throttles"].invoke
      end
      throttles = JSON.parse(stdout)
      magic_link = throttles.find { |throttle| throttle.fetch("id") == "magic_links.consume" }

      assert_equal ["/v/:token", "/moja-platforma/v/:token"], magic_link.fetch("paths")
    end
  end

  def test_throttles_task_expands_root_mount_without_double_slashes
    with_env("PUBLIC_MOUNT_PATH" => "/", "SHORT_MAGIC_LINKS" => "0") do
      stdout, = capture_io do
        @rake["decidim_bih:host_contract:throttles"].invoke
      end
      throttles = JSON.parse(stdout)
      chat = throttles.find { |throttle| throttle.fetch("id") == "chat.create" }
      chat_feedback = throttles.find { |throttle| throttle.fetch("id") == "chat.feedback" }
      corroborate = throttles.find { |throttle| throttle.fetch("id") == "reports.corroborate" }

      assert_equal ["/chat"], chat.fetch("paths")
      assert_equal ["/chat/feedback"], chat_feedback.fetch("paths")
      assert_equal ["\\A/prijave/[^/]+/potvrdi\\z"], corroborate.fetch("path_regexes")
    end
  end

  def test_providers_task_prints_provider_contract_manifest
    stdout, = capture_io do
      @rake["decidim_bih:host_contract:providers"].invoke
    end
    providers = JSON.parse(stdout)

    assert(providers.any? { |contract| contract.fetch("id") == "donations_provider" })
    assert(providers.any? { |contract| contract.fetch("id") == "city_data_freshness_provider" })
    assert(providers.all? { |contract| contract.fetch("required_methods").is_a?(Array) })
  end

  def test_decidim_modules_task_prints_hard_dependency_manifest
    stdout, = capture_io do
      @rake["decidim_bih:host_contract:decidim_modules"].invoke
    end
    modules = JSON.parse(stdout)
    module_gems = modules.map { |mod| mod.fetch("gem") }

    assert_includes module_gems, "decidim-core"
    assert_includes module_gems, "decidim-budgets"
    assert_includes module_gems, "decidim-verifications"
    assert(modules.all? { |mod| mod.fetch("status") == "hard_runtime_dependency" })
  end

  def test_privacy_audit_task_prints_retention_and_event_contract_manifest
    with_env("PUBLIC_MOUNT_PATH" => "/moja-platforma") do
      stdout, = capture_io do
        @rake["decidim_bih:host_contract:privacy_audit"].invoke
      end
      contract = JSON.parse(stdout)
      bucket_ids = contract.fetch("retention_buckets").map { |bucket| bucket.fetch("id") }
      stream_ids = contract.fetch("audit_event_streams").map { |stream| stream.fetch("id") }
      public_impact = contract.fetch("audit_event_streams").find { |stream| stream.fetch("id") == "public_impact_summary" }

      assert_equal 1, contract.fetch("version")
      assert_includes bucket_ids, "report_contacts"
      assert_includes bucket_ids, "chat_feedback"
      assert_includes stream_ids, "report_events"
      assert_includes stream_ids, "admin_analytics_exports"
      assert_includes stream_ids, "governance_approvals"
      assert_includes public_impact.fetch("consumers"), "/moja-platforma/uticaj"
      assert_includes contract.fetch("required_exclusion_terms"), "provider_payload"
    end
  end

  def test_public_surfaces_task_prints_mount_expanded_review_manifest
    with_env("PUBLIC_MOUNT_PATH" => "/moja-platforma") do
      stdout, = capture_io do
        @rake["decidim_bih:host_contract:public_surfaces"].invoke
      end
      surfaces = JSON.parse(stdout)
      report_form = surfaces.find { |surface| surface.fetch("id") == "reports.new" }
      hub = surfaces.find { |surface| surface.fetch("id") == "community_hub.show" }

      assert_equal ["/moja-platforma/prijave/new"], report_form.fetch("paths")
      assert_equal "decidim.bih.menu.community_hub", hub.fetch("menu_i18n_key")
      assert_equal true, hub.fetch("public_nav")
      assert_equal true, hub.fetch("stable_compatibility_path")
    end
  end

  def test_public_writes_task_prints_mount_expanded_classification_manifest
    with_env("PUBLIC_MOUNT_PATH" => "/moja-platforma") do
      stdout, = capture_io do
        @rake["decidim_bih:host_contract:public_writes"].invoke
      end
      routes = JSON.parse(stdout)
      suggest = routes.find { |route| route.fetch("id") == "komsiluk.suggest" }
      organization_create = routes.find { |route| route.fetch("id") == "organizations.create" }

      assert_equal ["/moja-platforma/komsiluk/suggest"], suggest.fetch("paths")
      assert_equal ["komsiluk.suggest_by_ip", "komsiluk.suggest_by_session"], suggest.fetch("throttle_ids")
      assert_equal %w(organizations.write_by_ip organizations.write_by_session),
                   organization_create.fetch("throttle_ids")
    end
  end

  def test_full_manifest_includes_provider_contracts
    stdout, = capture_io do
      @rake["decidim_bih:host_contract:manifest"].invoke
    end
    manifest = JSON.parse(stdout)
    provider_ids = manifest.fetch("required_provider_contracts").map { |contract| contract.fetch("id") }
    write_ids = manifest.fetch("required_public_write_routes").map { |route| route.fetch("id") }
    surface_ids = manifest.fetch("required_public_surfaces").map { |surface| surface.fetch("id") }
    brand_asset_ids = manifest.fetch("required_brand_asset_reviews").map { |asset| asset.fetch("id") }
    module_gems = manifest.fetch("required_decidim_modules").map { |mod| mod.fetch("gem") }
    privacy_contract = manifest.fetch("privacy_audit_contract")
    privacy_stream_ids = privacy_contract.fetch("audit_event_streams").map { |stream| stream.fetch("id") }

    assert_includes provider_ids, "donations_provider"
    assert_includes provider_ids, "infobip_client"
    assert_includes provider_ids, "sistem48_archive"
    assert_includes write_ids, "komsiluk.suggest"
    assert_includes write_ids, "volunteer.signup"
    assert_includes surface_ids, "reports.new"
    assert_includes surface_ids, "mz_directory.index"
    assert_includes brand_asset_ids, "theme_and_fonts"
    assert_includes brand_asset_ids, "stickers"
    assert_includes module_gems, "decidim-proposals"
    assert_includes module_gems, "decidim-verifications"
    assert_includes privacy_stream_ids, "report_events"
    assert_includes privacy_stream_ids, "privacy_retention_runs"
    assert_includes privacy_stream_ids, "governance_approvals"
  end

  private

  def with_env(values)
    previous = values.to_h { |key, _value| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end

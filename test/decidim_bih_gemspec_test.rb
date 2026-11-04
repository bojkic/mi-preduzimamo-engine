# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class DecidimBihGemspecTest < Minitest::Test
  def spec
    @spec ||= Gem::Specification.load(File.expand_path("../decidim-bih.gemspec", __dir__))
  end

  def test_dependency_resolution_rejects_unpatched_ransack_before_boot
    dependency = spec.runtime_dependencies.find { |item| item.name == "ransack" }
    assert dependency, "the boot-time security guard must also constrain fresh dependency resolution"
    %w(4.4.1 4.4.2 4.5.0 5.0.0).each do |version|
      refute dependency.requirement.satisfied_by?(Gem::Version.new(version)), version
    end
    %w(4.4.3 4.4.4).each do |version|
      assert dependency.requirement.satisfied_by?(Gem::Version.new(version)), version
    end
  end

  def test_engine_migrations_are_packaged
    assert spec.files.any? { |path| path.start_with?("db/migrate/") },
           "engine gem must package db/migrate so host apps can install migrations"
  end

  def test_public_assets_are_packaged
    Decidim::Bih.required_public_assets.each do |asset|
      assert_includes spec.files, "public/#{asset.delete_prefix("/")}"
    end

    assert_includes spec.files, "public/ASSET_NOTICE.md"
  end

  def test_generator_contract_files_are_packaged
    assert_includes spec.files, "lib/generators/decidim/bih/install_generator.rb"
    assert_includes spec.files, "lib/generators/decidim/bih/templates/decidim_bih.rb.erb"
    assert_includes spec.files, "lib/generators/decidim/bih/templates/decidim_bih_rack_attack.rb.erb"
  end

  def test_productization_docs_and_smoke_script_are_packaged
    assert_includes spec.files, "docs/BRAND_ASSET_REPLACEMENT.md"
    assert_includes spec.files, "docs/ENGINE_CONTRACT.md"
    assert_includes spec.files, "docs/PROVIDER_INTERFACES.md"
    assert_includes spec.files, "docs/PRIVACY_AUDIT_CONTRACT.md"
    assert_includes spec.files, "script/decidim_bih_clean_host_smoke"
    assert_includes spec.files, "script/decidim_bih_generated_host_database"
    assert_includes spec.files, "script/decidim_bih_rails_test"
    assert_includes spec.files, "rails_test/test_helper.rb"
    assert_includes spec.files, "rails_test/goodwill_redemption_flow_test.rb"
    assert_includes spec.files, "rails_test/public_surface_smoke_test.rb"
  end

  def test_clean_host_smoke_can_use_external_generator_gemfile
    script = File.read(File.expand_path("../script/decidim_bih_clean_host_smoke", __dir__))

    assert_includes script, "DECIDIM_BIH_CLEAN_HOST_GENERATOR_GEMFILE"
    assert_includes script, "prune_unbundled_decidim_migrations"
    assert_includes script, 'suffix.sub(/\Adecidim_/, "decidim-")'
  end

  def test_generated_host_scripts_use_shared_database_isolation_before_cleanup
    %w(decidim_bih_clean_host_smoke decidim_bih_rails_test).each do |name|
      script = File.read(File.expand_path("../script/#{name}", __dir__))

      assert_includes script, "decidim_bih_generated_host_database"
      assert_includes script, "decidim_bih_prepare_database_isolation"
      assert_includes script, 'decidim_bih_patch_generated_database_config "config/database.yml"'
      assert_includes script, "decidim_bih_install_schema_extension_guard"
      assert_includes script, "decidim_bih_preflight_database_isolation"
      assert_includes script, "decidim_bih_create_database_isolation"
      assert_includes script, "decidim_bih_cleanup_database_isolation"
      assert_operator script.index("decidim_bih_prepare_database_isolation"), :<, script.index("trap cleanup EXIT")
      assert_operator script.index("decidim_bih_patch_generated_database_config"),
                      :<,
                      script.index("decidim_bih_create_database_isolation")
      refute_includes script, "bin/rails db:create"
      refute_includes script, "bin/rails db:drop"
      assert_match(/RUN_NONCE=.*BASHPID.*RANDOM/, script)
    end
  end

  def test_generated_host_database_helper_requires_ownership_before_cleanup
    helper = File.read(File.expand_path("../script/decidim_bih_generated_host_database", __dir__))

    assert_includes helper, "DECIDIM_BIH_GENERATED_HOST_DATABASE_OWNED=0"
    assert_includes helper, "DECIDIM_BIH_GENERATED_HOST_DATABASE_OWNED=1"
    assert_includes helper, '[[ "${DECIDIM_BIH_GENERATED_HOST_DATABASE_OWNED:-0}" == "1" ]] || return 0'
    assert_includes helper, "target schema already exists"
    assert_includes helper, "ownership marker mismatch"
    assert_includes helper, "rejects DATABASE_URL"
    refute_includes helper, "decidim_bih_url_database_command"
    assert_includes helper, "must not have CREATE on extension schema"
    assert_includes helper, "extension schema has unrelated objects"
    assert_includes helper, "DECIDIM_BIH_GENERATED_HOST_EXTENSION_SCHEMA"
    assert_includes helper, '"  advisory_locks: false\\n"'
  end

  def test_rails_backed_harness_disables_parallel_database_preparation
    script = File.read(File.expand_path("../script/decidim_bih_rails_test", __dir__))

    assert_includes script, "PARALLEL_WORKERS=1"
    assert_match(/PARALLEL_WORKERS=1.*\\
\s+DECIDIM_BIH_RAILS_APP=.*\\
\s+ruby -I/, script)
  end

  def test_direct_runtime_dependencies_are_declared
    dependency_names = spec.dependencies.select(&:runtime?).map(&:name)

    assert_includes dependency_names, "decidim-budgets"
    assert_includes dependency_names, "decidim-forms"
    assert_includes dependency_names, "decidim-meetings"
    assert_includes dependency_names, "decidim-proposals"
    assert_includes dependency_names, "decidim-verifications"
    assert_includes dependency_names, "mini_magick"
    assert_includes dependency_names, "redis"
    assert_includes dependency_names, "rqrcode"
  end

  def test_required_decidim_module_contract_matches_gemspec_runtime_dependencies
    dependency_names = spec.dependencies.select(&:runtime?).map(&:name)
    required_module_gems = Decidim::Bih.required_decidim_modules.map { |mod| mod.fetch(:gem) }

    assert_empty required_module_gems - dependency_names
  end
end

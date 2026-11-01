# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "digest"
require "fileutils"
require "open3"
require "rack/attack"
require "rack"
require "rbconfig"
require_relative "../../app/services/decidim/bih/throttling"
require "tmpdir"

class GeneratedHostDatabaseIsolationTest < Minitest::Test
  HELPER = File.expand_path("../../script/decidim_bih_generated_host_database", __dir__)
  APP_NAME = "decidim_bih_clean_host_20260812090000_12345_6789_9876"
  RAILS_APP_NAME = "decidim_bih_rails_test_20260812090000_12345_6789_9876"

  def test_rails_harness_checks_applied_versions_before_disabling_automatic_schema_maintenance
    sandbox, preflight, active_record, calls = rails_schema_preflight(pending: false)

    sandbox.module_eval(preflight)

    assert_equal [:read_pending_versions, [:automatic_maintenance, false]], calls
    refute active_record.maintain_test_schema
  end

  def test_rails_harness_rejects_pending_migrations_without_disabling_the_check
    sandbox, preflight, active_record, calls = rails_schema_preflight(pending: true)

    assert_raises(active_record.const_get(:PendingMigrationError)) { sandbox.module_eval(preflight) }

    assert_equal [:read_pending_versions], calls
    assert active_record.maintain_test_schema
  end

  def test_missing_database_url_uses_unique_schema_in_default_test_database
    stdout, stderr, status = run_helper(
      { "DATABASE_URL" => nil, "DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE" => nil },
      <<~'SH'
        decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
        printf '%s\n%s\n%s\n' \
          "$DECIDIM_BIH_GENERATED_HOST_DATABASE_MODE" \
          "$DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE" \
          "$DECIDIM_BIH_GENERATED_HOST_TEST_SCHEMA"
      SH
    )

    assert status.success?, stderr
    mode, database, schema = stdout.lines.map(&:chomp)
    assert_equal "schema", mode
    assert_equal "decidim_app_test", database
    assert_match(/\Adbih_clean_host_\d{14}_\d+_\d+_\d+\z/, schema)
  end

  def test_schema_fallback_accepts_an_explicit_test_database
    stdout, stderr, status = run_helper(
      {
        "DATABASE_URL" => nil,
        "APP_NAME" => RAILS_APP_NAME,
        "DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE" => "second_host_test-1"
      },
      <<~'SH'
        decidim_bih_prepare_database_isolation rails_test "$APP_NAME"
        printf '%s\n%s\n' \
          "$DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE" \
          "$DECIDIM_BIH_GENERATED_HOST_TEST_SCHEMA"
      SH
    )

    assert status.success?, stderr
    database, schema = stdout.lines.map(&:chomp)
    assert_equal "second_host_test-1", database
    assert_match(/\Adbih_rails_test_\d{14}_\d+_\d+_\d+\z/, schema)
  end

  def test_schema_fallback_rejects_non_test_and_production_like_databases
    %w(postgres decidim_production city_prod_test decidim_production_test).each do |database|
      _stdout, stderr, status = run_helper(
        {
          "DATABASE_URL" => nil,
          "DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE" => database
        },
        'decidim_bih_prepare_database_isolation clean_host "$APP_NAME"'
      )

      refute status.success?, database
      assert_includes stderr, "explicit non-production test database", database
    end
  end

  def test_database_url_is_always_rejected
    _stdout, stderr, status = run_helper(
      { "DATABASE_URL" => "postgresql://test_user@example.test/safe_test" },
      'decidim_bih_prepare_database_isolation clean_host "$APP_NAME"'
    )

    refute status.success?
    assert_includes stderr, "rejects DATABASE_URL"
  end

  def test_prepare_starts_unowned_and_cleanup_is_a_noop
    stdout, stderr, status = run_helper(
      { "DATABASE_URL" => nil },
      <<~'SH'
        decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
        decidim_bih_cleanup_database_isolation
        printf '%s\n' "$DECIDIM_BIH_GENERATED_HOST_DATABASE_OWNED"
      SH
    )

    assert status.success?, stderr
    assert_equal "0\n", stdout
  end

  def test_prepare_rejects_database_identifiers_over_postgresql_limit
    long_name = "decidim_bih_clean_host_#{"1" * 50}"
    _stdout, stderr, status = run_helper(
      { "DATABASE_URL" => nil, "APP_NAME" => long_name },
      'decidim_bih_prepare_database_isolation clean_host "$APP_NAME"'
    )

    refute status.success?
    assert_includes stderr, "unsafe generated-host database identity"
  end

  def test_ownership_arms_only_after_create_and_cleanup_failure_propagates
    stdout, stderr, status = run_helper(
      { "DATABASE_URL" => nil },
      <<~'SH'
        decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
        decidim_bih_schema_command() { return 0; }
        decidim_bih_create_database_isolation
        printf 'armed=%s\n' "$DECIDIM_BIH_GENERATED_HOST_DATABASE_OWNED"
        decidim_bih_schema_command() { return 73; }
        if decidim_bih_cleanup_database_isolation; then
          printf 'cleanup=unexpected-success\n'
          exit 1
        else
          cleanup_status=$?
          printf 'cleanup_status=%s\nstill_owned=%s\n' \
            "$cleanup_status" "$DECIDIM_BIH_GENERATED_HOST_DATABASE_OWNED"
        fi
      SH
    )

    assert status.success?, stderr
    assert_includes stdout, "armed=1\n"
    assert_includes stdout, "cleanup_status=73\n"
    assert_includes stdout, "still_owned=1\n"
  end

  def test_failed_create_does_not_arm_cleanup
    stdout, stderr, status = run_helper(
      { "DATABASE_URL" => nil },
      <<~'SH'
        decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
        decidim_bih_schema_command() { return 74; }
        if decidim_bih_create_database_isolation; then
          exit 1
        else
          create_status=$?
          printf 'create_status=%s\nowned=%s\n' \
            "$create_status" "$DECIDIM_BIH_GENERATED_HOST_DATABASE_OWNED"
        fi
      SH
    )

    assert status.success?, stderr
    assert_includes stdout, "create_status=74\n"
    assert_includes stdout, "owned=0\n"
  end

  def test_schema_extension_guard_forbids_database_wide_extension_changes
    Dir.mktmpdir("decidim-bih-extension-guard") do |directory|
      initializer_path = File.join(directory, "database_guard.rb")
      _stdout, stderr, status = run_helper(
        { "DATABASE_URL" => nil, "INITIALIZER_PATH" => initializer_path },
        <<~SH
          decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
          decidim_bih_install_schema_extension_guard "$INITIALIZER_PATH"
        SH
      )

      assert status.success?, stderr
      guard = File.read(initializer_path)
      assert_includes guard, "cannot add database extension"
      assert_includes guard, "cannot remove database extension"
      assert_includes guard, "return if extension_enabled?(name)"
      assert_includes guard, '"?(?:public|decidim_bih_extensions)"?'
      assert_includes guard, "@decidim_bih_setting_generated_host_search_path"
      assert_includes guard, '"pg_catalog"'
      assert_includes guard, '"information_schema"'
      assert_includes guard, "reject_unsafe_qualified_relations!"
      assert_includes guard, '"server or security DDL"'
    end
  end

  def test_preflight_source_guard_rejects_quoted_shared_schema_targets
    Dir.mktmpdir("decidim-bih-migration-boundary") do |directory|
      migration_path = File.join(directory, "20260812000000_escape.rb")
      File.write(migration_path, <<~RUBY)
        class Escape < ActiveRecord::Migration[7.2]
          def change
            execute %(UPDATE "public"."citizens" SET active = false)
          end
        end
      RUBY

      _stdout, stderr, status = run_helper(
        { "DATABASE_URL" => nil, "MIGRATION_ROOT" => directory },
        <<~SH
          decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
          decidim_bih_preflight_database_isolation "$MIGRATION_ROOT"
        SH
      )

      refute status.success?
      assert_match(/shared schema reference|schema-qualified relation/, stderr)
    end
  end

  def test_preflight_source_guard_rejects_server_security_sql
    Dir.mktmpdir("decidim-bih-migration-boundary") do |directory|
      migration_path = File.join(directory, "20260812000000_escape.rb")
      File.write(migration_path, <<~RUBY)
        class Escape < ActiveRecord::Migration[7.2]
          def change
            execute %(CREATE ROLE generated_host_escape LOGIN)
          end
        end
      RUBY

      _stdout, stderr, status = run_helper(
        { "DATABASE_URL" => nil, "MIGRATION_ROOT" => directory },
        <<~SH
          decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
          decidim_bih_preflight_database_isolation "$MIGRATION_ROOT"
        SH
      )

      refute status.success?
      assert_includes stderr, "server or security SQL is forbidden"
    end
  end

  def test_generated_guard_allows_join_aliases_but_rejects_other_schemas
    Dir.mktmpdir("decidim-bih-runtime-guard") do |directory|
      initializer_path = File.join(directory, "database_guard.rb")
      _stdout, stderr, status = run_helper(
        { "DATABASE_URL" => nil, "INITIALIZER_PATH" => initializer_path },
        <<~SH
          decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
          decidim_bih_install_schema_extension_guard "$INITIALIZER_PATH"
        SH
      )
      assert status.success?, stderr

      probe = <<~RUBY
        module ActiveRecord
          module ConnectionAdapters
            class PostgreSQLAdapter
              attr_reader :statements

              def initialize
                @statements = []
              end

              def raw_execute(sql, *)
                @statements << sql
              end
            end
          end
        end

        load ENV.fetch("INITIALIZER_PATH")
        adapter = ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.new
        adapter.send(:raw_execute, "SELECT * FROM citizens x JOIN wards y ON x.ward_id = y.id")
        adapter.send(:raw_execute, "SELECT * FROM pg_catalog.pg_class")
        adapter.send(:raw_execute, "UPDATE memberships SET role = 'creator'")
        abort "safe SQL was not delegated" unless adapter.statements.length == 3

        begin
          adapter.send(:raw_execute, %(SELECT * FROM "another_schema"."citizens"))
          abort "qualified relation was accepted"
        rescue RuntimeError => error
          abort error.message unless error.message.include?("schema-qualified relation")
        end

        forbidden_statements = [
          "CREATE ROLE generated_host_escape LOGIN",
          "ALTER SYSTEM SET work_mem = '1GB'",
          "CREATE TABLESPACE escaped LOCATION '/tmp/escaped'",
          "CREATE SERVER escaped FOREIGN DATA WRAPPER postgres_fdw",
          "CREATE PUBLICATION escaped FOR ALL TABLES",
          "CREATE SUBSCRIPTION escaped CONNECTION 'host=example.test' PUBLICATION escaped",
          "CREATE EVENT TRIGGER escaped ON ddl_command_start EXECUTE FUNCTION escaped()",
          "CREATE FOREIGN DATA WRAPPER escaped",
          "CREATE ACCESS METHOD escaped TYPE TABLE HANDLER escaped_handler",
          "SET SESSION AUTHORIZATION escaped",
          "LOAD '/tmp/escaped.so'",
          "COPY citizens TO PROGRAM 'touch /tmp/escaped'",
          "SECURITY LABEL ON TABLE citizens IS 'escaped'"
        ]
        forbidden_statements.each do |statement|
          begin
            adapter.send(:raw_execute, statement)
            abort "server/security SQL was accepted: \#{statement}"
          rescue RuntimeError => error
            abort error.message unless error.message.include?("server or security DDL")
          end
        end
      RUBY
      stub_root = File.join(directory, "stubs")
      adapter_stub = File.join(stub_root, "active_record", "connection_adapters")
      FileUtils.mkdir_p(adapter_stub)
      File.write(File.join(adapter_stub, "postgresql_adapter.rb"), "# test stub\n")
      _stdout, stderr, status = Open3.capture3(
        {
          "INITIALIZER_PATH" => initializer_path,
          "DECIDIM_BIH_GENERATED_HOST_TEST_SCHEMA" => "dbih_clean_host_20260812090000_12345_6789_9876",
          "DECIDIM_BIH_GENERATED_HOST_EXTENSION_SCHEMA" => "decidim_bih_extensions"
        },
        RbConfig.ruby,
        "-I#{stub_root}",
        "-e",
        probe
      )

      assert status.success?, stderr
    end
  end

  def test_schema_mode_patches_only_the_generated_test_database_config
    Dir.mktmpdir("decidim-bih-database-isolation") do |directory|
      config_path = File.join(directory, "database.yml")
      File.write(
        config_path,
        <<~YAML
          default: &default
            adapter: postgresql
          development:
            <<: *default
            database: sample_development
          test:
            <<: *default
            database: sample_test<%= ENV.fetch('TEST_ENV_NUMBER', "") %>
            schema_search_path: old_schema,public
            advisory_locks: true
          production:
            <<: *default
            url: <%= ENV['DATABASE_URL'] %>
        YAML
      )

      _stdout, stderr, status = run_helper(
        { "DATABASE_URL" => nil, "CONFIG_PATH" => config_path },
        <<~SH
          decidim_bih_prepare_database_isolation clean_host "$APP_NAME"
          decidim_bih_patch_generated_database_config "$CONFIG_PATH"
        SH
      )

      assert status.success?, stderr
      config = File.read(config_path)
      assert_includes config, "database: sample_development"
      assert_includes config, 'database: <%= ENV.fetch("DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE") %>'
      assert_includes config,
                      'schema_search_path: <%= ENV.fetch("DECIDIM_BIH_GENERATED_HOST_TEST_SCHEMA") %>,' \
                      '<%= ENV.fetch("DECIDIM_BIH_GENERATED_HOST_EXTENSION_SCHEMA") %>'
      assert_includes config, "advisory_locks: false"
      assert_equal 1, config.scan("schema_search_path:").length
      assert_equal 1, config.scan("advisory_locks:").length
      assert_includes config, "url: <%= ENV['DATABASE_URL'] %>"
      refute_includes config, "sample_test"
      refute_includes config, "old_schema"
    end
  end

  def test_clean_host_migrates_baseline_before_engine_and_runs_both_phases
    Dir.mktmpdir("decidim-bih-generated-order") do |directory|
      events_path = File.join(directory, "events.log")
      _stdout, stderr, status = run_clean_host_smoke(directory, events_path)

      assert status.success?, stderr
      assert_equal(
        %w(baseline_bundle_install baseline_bundle_prune schema_create baseline_migration
           engine_bundle_install engine_generator engine_migration runner schema_drop),
        File.readlines(events_path, chomp: true)
      )
    end
  end

  def test_clean_host_baseline_bundle_failure_stops_before_pruning_or_database_changes
    Dir.mktmpdir("decidim-bih-generated-order") do |directory|
      events_path = File.join(directory, "events.log")
      _stdout, _stderr, status = run_clean_host_smoke(directory, events_path, fail_baseline_bundle: true)

      refute status.success?
      assert_equal 31, status.exitstatus
      assert_equal %w(baseline_bundle_install), File.readlines(events_path, chomp: true)
    end
  end

  def test_clean_host_baseline_failure_does_not_add_engine_and_cleans_owned_schema
    Dir.mktmpdir("decidim-bih-generated-order") do |directory|
      events_path = File.join(directory, "events.log")
      _stdout, _stderr, status = run_clean_host_smoke(directory, events_path, fail_baseline: true)

      assert_equal false, status.success?
      assert_equal %w(baseline_bundle_install baseline_bundle_prune schema_create baseline_migration schema_drop), File.readlines(events_path, chomp: true)
    end
  end

  def test_clean_host_throttle_probe_uses_the_generated_session_discriminator
    template = File.read(RACK_ATTACK_TEMPLATE)
    fragment = template[/^public_session_id = lambda do.*?(?=^organizations_path =)/m]
    refute_nil fragment

    original_throttles = Rack::Attack.throttles.dup
    Rack::Attack.throttles.clear
    mount_path = "/moja-platforma"
    mount_prefix = mount_path == "/" ? "" : mount_path
    mounted_path = ->(suffix) { "#{mount_prefix}/#{suffix.to_s.delete_prefix("/")}" }
    eval(fragment, binding, RACK_ATTACK_TEMPLATE, 1) # rubocop:disable Security/Eval -- Only the tracked template fixture is evaluated.

    session_id = "fixture-session"
    session_key = "s:#{Digest::SHA256.hexdigest(session_id)[0, 32]}"
    session = Struct.new(:id).new(session_id)
    env = Rack::MockRequest.env_for(
      "/moja-platforma/projekti/prijave/123",
      :method => "PATCH",
      "REMOTE_ADDR" => "203.0.113.10"
    )
    env["rack.session"] = session
    request = Rack::Request.new(env)
    assert_equal session_key,
                 Rack::Attack.throttles.fetch("bih/community-contributions.write/session").block.call(request)

    anonymous_env = Rack::MockRequest.env_for(
      "/moja-platforma/projekti/prijave/123",
      :method => "PATCH",
      "REMOTE_ADDR" => "203.0.113.10"
    )
    anonymous_request = Rack::Request.new(anonymous_env)
    assert_equal "ip:203.0.113.10",
                 Rack::Attack.throttles.fetch("bih/community-contributions.write/session").block.call(anonymous_request)
  ensure
    Rack::Attack.throttles.clear
    Rack::Attack.throttles.merge!(original_throttles) if original_throttles
  end

  def test_clean_host_throttle_probe_uses_the_generated_salted_phone_key
    template = File.read(RACK_ATTACK_TEMPLATE)
    fragment = template[%r{^Rack::Attack\.throttle\("bih/phone-login/phone".*?^end$}m]
    refute_nil fragment

    original_throttles = Rack::Attack.throttles.dup
    Rack::Attack.throttles.clear
    mount_path = "/moja-platforma"
    mount_prefix = mount_path == "/" ? "" : mount_path
    mounted_path = ->(suffix) { "#{mount_prefix}/#{suffix.to_s.delete_prefix("/")}" }

    with_test_secret("generated-host-test-secret") do
      eval(fragment, binding, RACK_ATTACK_TEMPLATE, 1) # rubocop:disable Security/Eval -- Only the tracked template fixture is evaluated.

      canonical = Decidim::Bih::Throttling.phone_key("+38765123456")
      formatted = Decidim::Bih::Throttling.phone_key(" +387 65/123-456 ")
      assert_match(/\A\h{64}\z/, canonical)
      assert_equal canonical, formatted
      refute_includes canonical, "38765123456"
      assert_nil Decidim::Bih::Throttling.phone_key("not-a-phone")

      env = Rack::MockRequest.env_for(
        "/moja-platforma/prijava",
        :method => "POST",
        :params => { "phone" => "+38765123456" },
        "REMOTE_ADDR" => "203.0.113.10"
      )
      request = Rack::Request.new(env)
      assert_equal canonical,
                   Rack::Attack.throttles.fetch("bih/phone-login/phone").block.call(request)

      invalid_env = Rack::MockRequest.env_for(
        "/moja-platforma/prijava",
        :method => "POST",
        :params => { "phone" => "not-a-phone" },
        "REMOTE_ADDR" => "203.0.113.10"
      )
      invalid_request = Rack::Request.new(invalid_env)
      assert_nil Rack::Attack.throttles.fetch("bih/phone-login/phone").block.call(invalid_request)
    end
  ensure
    Rack::Attack.throttles.clear
    Rack::Attack.throttles.merge!(original_throttles) if original_throttles
  end

  private

  CLEAN_HOST_ENGINE_ROOT = File.expand_path("../..", __dir__)
  CLEAN_HOST_SCRIPT = File.join(CLEAN_HOST_ENGINE_ROOT, "script", "decidim_bih_clean_host_smoke")
  RACK_ATTACK_TEMPLATE = File.join(
    CLEAN_HOST_ENGINE_ROOT,
    "lib/generators/decidim/bih/templates/decidim_bih_rack_attack.rb.erb"
  )
  CLEAN_HOST_RUBY = RbConfig.ruby

  def run_clean_host_smoke(directory, events_path, fail_baseline: false, fail_baseline_bundle: false)
    fake_bin = File.join(directory, "bin")
    work_root = File.join(directory, "work")
    generator_gemfile = File.join(directory, "generator.Gemfile")
    FileUtils.mkdir_p([fake_bin, work_root])
    File.write(generator_gemfile, "source \"https://rubygems.org\"\n")
    write_fake_clean_host_commands(fake_bin)

    environment = {
      "PATH" => "#{fake_bin}:#{File.dirname(CLEAN_HOST_RUBY)}:/usr/bin:/bin",
      "RBENV_ROOT" => "/nonexistent",
      "LANG" => "C.UTF-8",
      "ENGINE_ROOT" => CLEAN_HOST_ENGINE_ROOT,
      "REDIS_URL" => ENV.fetch("REDIS_URL"),
      "WORK_ROOT" => work_root,
      "APP_NAME" => "decidim_bih_clean_host_20260907154557_111_222_333",
      "EVENT_LOG" => events_path,
      "BUNDLE_INSTALL_FLAGS" => "--local --jobs=1",
      "MOUNT_PATH" => "/moja-platforma",
      "SHORT_MAGIC_LINKS" => "0",
      "KEEP_DECIDIM_BIH_CLEAN_HOST" => "0",
      "DECIDIM_BIH_CLEAN_HOST_GENERATOR_GEMFILE" => generator_gemfile,
      "DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE" => "decidim_app_test"
    }
    environment["FAIL_BASELINE"] = "1" if fail_baseline
    environment["FAIL_BASELINE_BUNDLE"] = "1" if fail_baseline_bundle

    Open3.capture3(environment, CLEAN_HOST_SCRIPT, unsetenv_others: true)
  end

  def with_test_secret(secret)
    defined_here = !defined?(Rails)
    Object.const_set(:Rails, Module.new) if defined_here
    had_application = Rails.respond_to?(:application)
    original_application = Rails.method(:application) if had_application
    fake_application = Struct.new(:secret_key_base).new(secret)
    Rails.define_singleton_method(:application) { fake_application }
    yield
  ensure
    Rails.singleton_class.send(:remove_method, :application)
    Rails.define_singleton_method(:application, original_application) if had_application
    Object.send(:remove_const, :Rails) if defined_here
  end

  def write_fake_clean_host_commands(fake_bin)
    write_fake_executable(fake_bin, "ruby", <<~SH)
      #!/usr/bin/env bash
      exec #{CLEAN_HOST_RUBY} "$@"
    SH

    write_fake_executable(fake_bin, "npm", <<~SH)
      #!/usr/bin/env bash
      exit 0
    SH

    write_fake_executable(fake_bin, "bundle", <<~SH)
      #!/usr/bin/env bash
      set -euo pipefail

      if [[ "${1:-}" == "install" ]]; then
        [[ "$*" == "install --local --jobs=1" ]] || exit 32
        if grep -q 'decidim-bih' Gemfile; then
          printf 'engine_bundle_install\\n' >> "$EVENT_LOG"
        else
          printf 'baseline_bundle_install\\n' >> "$EVENT_LOG"
          [[ "${FAIL_BASELINE_BUNDLE:-0}" != "1" ]] || exit 31
          touch tmp/baseline_bundle.ready
        fi
        exit 0
      fi

      if [[ "${1:-}" != "exec" ]]; then
        exit 0
      fi
      shift

      if [[ "${1:-}" == "decidim" ]]; then
        shift
        command decidim "$@"
        exit 0
      fi

      [[ "${1:-}" == "ruby" ]] || exit 0
      shift
      source_code="$(cat)"
      if grep -q 'require "bundler"' <<<"$source_code"; then
        if [[ ! -f tmp/baseline_bundle.ready ]]; then
          printf 'baseline_bundle_missing\\n' >> "$EVENT_LOG"
          exit 35
        fi
        printf 'baseline_bundle_prune\\n' >> "$EVENT_LOG"
        exit 0
      fi
      if [[ -n "${DECIDIM_BIH_GENERATED_HOST_SCHEMA_OPERATION:-}" ]]; then
        printf 'schema_%s\\n' "$DECIDIM_BIH_GENERATED_HOST_SCHEMA_OPERATION" >> "$EVENT_LOG"
        exit 0
      fi
      if grep -q 'ARGV.fetch(0)' <<<"$source_code" && ! grep -q 'PG.connect' <<<"$source_code"; then
        printf 'ltree,pg_trgm\\n'
      fi
    SH

    write_fake_executable(fake_bin, "decidim", <<~SH)
      #!/usr/bin/env bash
      set -euo pipefail
      app_root="$PWD/${1:?missing app name}"
      mkdir -p "$app_root/config" "$app_root/db/migrate" "$app_root/bin" "$app_root/public" "$app_root/tmp"
      printf 'source "https://rubygems.org"\\n' > "$app_root/Gemfile"
      : > "$app_root/Gemfile.lock"
      cat > "$app_root/config/database.yml" <<'YAML'
      test:
        database: decidim_app_test
      YAML
      printf 'Rails.application.routes.draw do\\n  mount Decidim::Core::Engine => "/"\\nend\\n' > "$app_root/config/routes.rb"
      cat > "$app_root/bin/rails" <<'RAILS'
      #!/usr/bin/env bash
      set -euo pipefail
      log_event() { printf '%s\\n' "$1" >> "$EVENT_LOG"; }
      case "${1:-}" in
        generate)
          log_event engine_generator
          ;;
        db:migrate)
          if grep -q 'decidim-bih' Gemfile; then
            log_event engine_migration
          else
            log_event baseline_migration
            if [[ "${FAIL_BASELINE:-0}" == "1" ]]; then exit 23; fi
          fi
          ;;
        runner)
          log_event runner
          ;;
      esac
      RAILS
      chmod +x "$app_root/bin/rails"
    SH
  end

  def write_fake_executable(fake_bin, name, contents)
    path = File.join(fake_bin, name)
    File.write(path, contents)
    FileUtils.chmod(0o755, path)
  end

  def rails_schema_preflight(pending:)
    source = File.read(File.expand_path("../../rails_test/test_helper.rb", __dir__))
    # Exercise only the schema guard in the isolated ActiveRecord sandbox.
    # Private storage setup after boot has its own real attachment regressions.
    preflight = source[/^raise ActiveRecord::PendingMigrationError.*?^ActiveRecord\.maintain_test_schema = false$/m]
    raise "Rails harness schema preflight missing" unless preflight

    calls = []
    context = Object.new
    context.define_singleton_method(:needs_migration?) do
      calls << :read_pending_versions
      pending
    end
    pool = Object.new
    pool.define_singleton_method(:migration_context) { context }
    base = Class.new
    base.define_singleton_method(:connection_pool) { pool }
    active_record = Module.new
    active_record.const_set(:Base, base)
    active_record.const_set(:PendingMigrationError, Class.new(StandardError))
    active_record.instance_variable_set(:@maintain_test_schema, true)
    active_record.define_singleton_method(:maintain_test_schema) { @maintain_test_schema }
    active_record.define_singleton_method(:maintain_test_schema=) do |value|
      calls << [:automatic_maintenance, value]
      @maintain_test_schema = value
    end
    sandbox = Module.new
    sandbox.const_set(:ActiveRecord, active_record)
    [sandbox, preflight, active_record, calls]
  end

  def run_helper(environment, command)
    Open3.capture3(
      { "HELPER" => HELPER, "APP_NAME" => APP_NAME, "DECIDIM_BIH_GENERATED_HOST_TEST_DATABASE" => nil }.merge(environment),
      "/bin/bash",
      "-c",
      "set -euo pipefail; source \"$HELPER\"; #{command}"
    )
  end
end

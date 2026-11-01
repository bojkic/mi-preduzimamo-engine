# frozen_string_literal: true

require "test_helper"
require "ipaddr"
require "json"
require "minitest/mock"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "decidim/bih/redis_endpoint"

module Decidim
  module Bih
    class RedisEndpointTest < Minitest::Test
      ROOT = File.expand_path("../../../..", __dir__)
      TEST_URL = "redis://127.0.0.1:6379/15"
      PRODUCTION_LIKE = %w(
        redis://127.0.0.1:6379/0
        redis://127.0.0.1:6379/1
        redis://localhost:6379/1
        redis://localhost/0
        redis://localhost
        redis://127.0.0.1:6379
        redis://[::1]:6379/1
        redis://127.0.0.1:6379?db=1
        redis://127.0.0.1:6379?db=15
        redis://127.0.0.1:6379/?db=15
        redis://localhost.:6379/1
        redis://127.1:6379/0
        redis://[::ffff:127.0.0.1]:6379/0
        redis://0.0.0.0:6379/0
        rediss://localhost:6379/0
        unix:///run/redis/redis-server.sock
        unix:///var/run/redis/redis.sock?db=15
      ).freeze

      # A dedicated-instance fixture credential (plan item 7): forces dedicated
      # mode in a child through MI_TEST_REDIS_URL_FILE on any machine.
      DEDICATED_URL = "redis://mi_test:dedicated-fixture@127.0.0.1:16390/15"

      # These cases judge task A's endpoint rules, which interim mode applies
      # alone. In-process they run against an absent install directory, so
      # they mean the same on a machine where the dedicated test Redis is
      # installed; installed mode is covered in test_redis_instance_test.rb
      # and by the child cases below, which see the real filesystem.
      def run(...)
        absent = File.join(Dir.tmpdir, "mi-test-redis-absent-#{Process.pid}-#{object_id}")
        raise "fixture install dir unexpectedly exists" if File.exist?(absent)

        TestRedisInstance.with_install_dir(absent) { super }
      end

      def setup
        @tmp = Dir.mktmpdir("redis-endpoint-")
      end

      # Children see the real filesystem: before the dedicated test Redis is
      # installed TEST_URL (db15) is the accepted interim endpoint, after it
      # every child refuses it. Both branches assert; nothing is skipped.
      def installed_here?
        File.directory?(TestRedisInstance::INSTALL_DIR)
      end

      def dedicated_fixture
        path = File.join(@tmp, "mi-test-redis/url")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{DEDICATED_URL}\n")
        path
      end

      def teardown
        FileUtils.remove_entry(@tmp)
      end

      def resolve(env, rails_env: "test")
        RedisEndpoint.url(env:, rails_env:)
      end

      def production_file(content)
        path = File.join(@tmp, "runtime.env")
        File.binwrite(path, content)
        path
      end

      # Real production resolution, in a fresh interpreter that never latches:
      # byte-identical to the expression every client used before
      # (ENV.fetch("REDIS_URL", "redis://localhost:6379/1")), for RAILS_ENV
      # production/development, through both the implicit and explicit
      # rails_env, and without reading any environment file.
      def test_production_resolution_is_byte_identical_in_an_unlatched_process
        probe = <<~RUBY
          require "json"
          require "decidim/bih/redis_endpoint"
          endpoint = Decidim::Bih::RedisEndpoint
          [File.singleton_class].each do |klass|
            %i(foreach read readlines open readable?).each do |name|
              klass.define_method(name) { |*| raise "environment file read outside test" }
            end
          end
          values = [nil, "", "redis://127.0.0.1:6379/0", "redis://:secret@10.0.0.5:6380/2", "unix:///run/redis/redis.sock"]
          rows = values.map do |value|
            value.nil? ? ENV.delete("REDIS_URL") : ENV.store("REDIS_URL", value)
            old = ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
            old_db0 = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
            [old, endpoint.url, endpoint.url(env: ENV, rails_env: ENV.fetch("RAILS_ENV")), endpoint.test_process?,
             old_db0, endpoint.url(fallback: endpoint::LOCAL_DB0_FALLBACK_URL)]
          end
          print JSON.generate(rows)
        RUBY
        %w(production development).each do |rails_env|
          out, err, status = Open3.capture3(base_env.merge("RAILS_ENV" => rails_env), RbConfig.ruby, "--disable-gems",
                                            "-I", File.join(ROOT, "lib"), "-e", probe, unsetenv_others: true)
          assert status.success?, err
          JSON.parse(out).each do |row|
            old, implicit, explicit, latched, old_db0, db0_client = row
            assert_equal old, implicit, rails_env
            assert_equal old, explicit, rails_env
            assert_equal old.b, implicit.b, rails_env
            assert_equal old_db0.b, db0_client.b, rails_env
            refute latched
          end
          assert_equal 5, JSON.parse(out).length
        end
        assert_equal "redis://localhost:6379/1", RedisEndpoint::LEGACY_FALLBACK_URL
      end

      # This suite's test_helper latched the process. A production Rails.env,
      # an explicit production rails_env or a production RAILS_ENV/RACK_ENV no
      # longer reaches the legacy fallback or skips the checks.
      def test_latched_process_ignores_production_environment_selectors
        assert RedisEndpoint.test_process?
        error = assert_raises(RedisEndpoint::Unconfigured) { RedisEndpoint.url(env: {}, rails_env: "production") }
        assert_includes error.message, "explicit test Redis endpoint"
        assert_raises(RedisEndpoint::Unconfigured) { RedisEndpoint.url(env: { "RAILS_ENV" => "production", "RACK_ENV" => "production" }) }
        assert_raises(RedisEndpoint::Refused) { RedisEndpoint.url(env: { "REDIS_URL" => "redis://127.0.0.1:6379/1" }, rails_env: "production") }
        assert_equal TEST_URL, RedisEndpoint.url(env: { "REDIS_URL" => TEST_URL }, rails_env: "production")
        # A per-client production fallback is never used on the test path.
        assert_raises(RedisEndpoint::Unconfigured) do
          RedisEndpoint.url(env: {}, rails_env: "production", fallback: RedisEndpoint::LOCAL_DB0_FALLBACK_URL)
        end
        assert_equal TEST_URL, RedisEndpoint.url(env: { "REDIS_URL" => TEST_URL }, fallback: RedisEndpoint::LOCAL_DB0_FALLBACK_URL)
      end

      # A process that starts as a test process latches when the resolver
      # loads, with no helper involved (standalone contracts), and later
      # selector changes cannot unlatch it. A production start never latches.
      def test_resolver_latches_a_process_that_starts_under_test
        probe = <<~'RUBY'
          require "decidim/bih/redis_endpoint"
          endpoint = Decidim::Bih::RedisEndpoint
          ENV["RAILS_ENV"] = "production"
          ENV["RACK_ENV"] = "production"
          module Rails
            def self.env = "production"
          end
          result = begin
            endpoint.url
          rescue endpoint::Error => e
            e.class.name.split("::").last
          end
          print "#{endpoint.test_process?} #{result}"
        RUBY
        { { "RAILS_ENV" => "test" } => "true Unconfigured", { "RACK_ENV" => "test" } => "true Unconfigured",
          { "RAILS_ENV" => "test", "REDIS_URL" => "redis://localhost:6379/1" } => "true Refused",
          { "RAILS_ENV" => "test", "REDIS_URL" => TEST_URL } => installed_here? ? "true Refused" : "true #{TEST_URL}",
          { "RAILS_ENV" => "test", "REDIS_URL" => DEDICATED_URL, "MI_TEST_REDIS_URL_FILE" => dedicated_fixture } => "true #{DEDICATED_URL}",
          { "RAILS_ENV" => "test", "REDIS_URL" => TEST_URL, "MI_TEST_REDIS_URL_FILE" => dedicated_fixture } => "true Refused",
          { "RAILS_ENV" => "test", "REDIS_URL" => "redis://127.0.0.1:16379/0", "MI_TEST_REDIS_URL_FILE" => dedicated_fixture } => "true Refused",
          { "RAILS_ENV" => "production" } => "false redis://localhost:6379/1" }.each do |env, expected|
          out, err, status = Open3.capture3(base_env.except("RAILS_ENV").merge(env), RbConfig.ruby, "--disable-gems",
                                            "-I", File.join(ROOT, "lib"), "-e", probe, unsetenv_others: true)
          assert status.success?, err
          assert_equal expected, out, env.inspect
        end
      end

      # The failure G reproduced, end to end in a fresh latched interpreter: a
      # stubbed production Rails.env (and RAILS_ENV) must refuse unset, db0,
      # db1 and the production-file URL before a client connects, and still
      # allow an explicit test endpoint. The "client" connects only to the two
      # local fixture listeners, never to port 6379.
      def test_latched_process_with_production_rails_env_refuses_before_connecting
        production = TCPServer.new("127.0.0.1", 0)
        test_server = TCPServer.new("127.0.0.1", 0)
        file = production_file("REDIS_URL=redis://127.0.0.1:#{production.addr[1]}/0\n")
        probe = <<~'RUBY'
          require "socket"
          require "decidim/bih/redis_endpoint"
          Decidim::Bih::RedisEndpoint.mark_test_process!
          module Rails
            def self.env = "production"
          end
          begin
            url = Decidim::Bih::RedisEndpoint.url
            host, port = url.match(%r{\Aredis://([^:/]+):(\d+)}).captures
            abort "would reach the production port" if Integer(port) == 6379
            TCPSocket.new(host, Integer(port)).close
            print "connected"
          rescue Decidim::Bih::RedisEndpoint::Error => e
            print e.class.name.split("::").last
          end
        RUBY
        cases = {
          nil => "Unconfigured",
          "redis://127.0.0.1:6379/0" => "Refused",
          "redis://localhost:6379/1" => "Refused",
          "redis://127.0.0.1:#{production.addr[1]}/0" => "Refused",
          "redis://#{Socket.gethostname}:6379/0" => "Refused",
          "redis://#{local_interface_address || "127.0.0.2"}:6379/1" => "Refused",
          # Interim: an explicit test endpoint connects. Installed (plan item 7):
          # only the credential's instance is allowed, so this listener is refused.
          "redis://127.0.0.1:#{test_server.addr[1]}/15" => installed_here? ? "Refused" : "connected"
        }
        cases.each do |url, expected|
          env = base_env.merge("RAILS_ENV" => "production", RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file)
          env["REDIS_URL"] = url if url
          out, err, status = Open3.capture3(env, RbConfig.ruby, "--disable-gems", "-I", File.join(ROOT, "lib"), "-e", probe,
                                            unsetenv_others: true)
          assert status.success?, "#{url.inspect}: #{err}"
          assert_equal expected, out, url.inspect
        end
        assert_nil accept_pending(production), "a refused process connected to the production fixture"
        if installed_here?
          assert_nil accept_pending(test_server), "an installed-mode process connected to a non-instance endpoint"
        else
          refute_nil accept_pending(test_server), "the explicit test endpoint was not reachable"
        end
      ensure
        production&.close
        test_server&.close
      end

      def test_resolver_raises_under_test_when_unset_or_blank
        [{}, { "REDIS_URL" => "" }, { "REDIS_URL" => "  " }].each do |env|
          error = assert_raises(RedisEndpoint::Unconfigured) { resolve(env) }
          assert_includes error.message, "explicit test Redis endpoint"
        end
      end

      # A fresh interpreter without Rails: the environment variables decide.
      def test_resolver_detects_test_from_environment_before_rails
        probe = <<~RUBY
          abort "Rails preloaded" if defined?(::Rails)
          require "decidim/bih/redis_endpoint"
          begin
            print Decidim::Bih::RedisEndpoint.url
          rescue Decidim::Bih::RedisEndpoint::Error => e
            print e.class.name.split("::").last
          end
        RUBY
        {
          { "RAILS_ENV" => "test" } => "Unconfigured",
          { "RACK_ENV" => "test" } => "Unconfigured",
          { "RAILS_ENV" => "test", "REDIS_URL" => TEST_URL } => installed_here? ? "Refused" : TEST_URL,
          { "RAILS_ENV" => "test", "REDIS_URL" => DEDICATED_URL, "MI_TEST_REDIS_URL_FILE" => dedicated_fixture } => DEDICATED_URL,
          { "RAILS_ENV" => "test", "REDIS_URL" => TEST_URL, "MI_TEST_REDIS_URL_FILE" => dedicated_fixture } => "Refused",
          { "RAILS_ENV" => "test", "REDIS_URL" => "redis://127.0.0.1:6379/1" } => "Refused",
          { "RAILS_ENV" => "production", "RACK_ENV" => "test" } => "redis://localhost:6379/1",
          { "RAILS_ENV" => "production", "REDIS_URL" => "redis://127.0.0.1:6379/0" } => "redis://127.0.0.1:6379/0",
          {} => "redis://localhost:6379/1"
        }.each do |env, expected|
          out, err, status = Open3.capture3(base_env.except("RAILS_ENV").merge(env), RbConfig.ruby, "--disable-gems",
                                            "-I", File.join(ROOT, "lib"), "-e", probe, unsetenv_others: true)
          assert status.success?, err
          assert_equal expected, out, env.inspect
        end
      end

      def test_refuses_production_databases_and_never_echoes_the_url
        PRODUCTION_LIKE.each do |url|
          error = assert_raises(RedisEndpoint::Refused, url) { resolve({ "REDIS_URL" => url }) }
          refute_includes error.message, url
        end
        error = assert_raises(RedisEndpoint::Refused) { resolve({ "REDIS_URL" => "redis://user:hunter2@127.0.0.1:6379/0" }) }
        refute_includes error.message, "hunter2"
      end

      def test_refuses_malformed_or_foreign_schemes
        ["http://127.0.0.1:6379/15", "redis://127.0.0.1:6379/x", "not a url", "unix:relative.sock"].each do |url|
          assert_raises(RedisEndpoint::Refused, url) { resolve({ "REDIS_URL" => url }) }
        end
      end

      def test_accepts_explicit_test_endpoints
        [TEST_URL, "redis://localhost:6379/15", "redis://127.0.0.1:16379/0", "unix:///run/redis-test/redis.sock"].each do |url|
          assert_equal url, resolve({ "REDIS_URL" => url })
        end
        assert RedisEndpoint.guard_test_environment!({ "REDIS_URL" => TEST_URL })
      end

      def test_refuses_an_endpoint_equal_to_the_production_environment_file
        file = production_file(%(SECRET_KEY_BASE=abc\nexport REDIS_URL="redis://:prod-pass@127.0.0.1:6390/3"\n))
        env = { "REDIS_URL" => "redis://localhost:6390/3", RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file }
        error = assert_raises(RedisEndpoint::Refused) { RedisEndpoint.guard_test_environment!(env) }
        assert_includes error.message, "production Redis endpoint"
        refute_includes error.message, "prod-pass"
        refute_includes error.message, "6390"
        # A different database on the same port is a different endpoint.
        assert RedisEndpoint.guard_test_environment!(env.merge("REDIS_URL" => "redis://127.0.0.1:6390/15"))
      end

      # The live .env format: comments, export prefixes, quotes, secrets and
      # non-Redis URLs. Only REDIS_*_URL values are parsed; nothing else is
      # interpreted, and no value reaches an error message.
      def test_scans_a_dotenv_style_file_for_redis_urls_only
        file = production_file(<<~ENV.b + "JUNK=\xFF\xFE\n".b)
          # REDIS_URL=redis://127.0.0.1:6393/9 is only a comment
          SECRET_KEY_BASE=super-secret-value
          DATABASE_URL=postgresql://decidim:pw@localhost/decidim_production
          export REDIS_URL='redis://:dotenv-pass@127.0.0.1:6394/0'
          REDIS_CACHE_URL = "redis://127.0.0.1:6395/2"
          NOT_REDIS_URL_EITHER=redis://127.0.0.1:6396/3
          REDIS_URL_BROKEN=http://example.invalid
        ENV
        endpoints = RedisEndpoint.endpoints_in(file).map(&:to_a)
        assert_equal [%w(tcp loopback) + [6394, 0], %w(tcp loopback) + [6395, 2]], endpoints
        env = { RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file }
        error = assert_raises(RedisEndpoint::Refused) { resolve(env.merge("REDIS_URL" => "redis://localhost:6394")) }
        %w(dotenv-pass super-secret-value 6394 decidim_production).each { |value| refute_includes error.message, value }
        assert_equal "redis://127.0.0.1:6393/9", resolve(env.merge("REDIS_URL" => "redis://127.0.0.1:6393/9"))
        assert_equal "redis://127.0.0.1:6396/3", resolve(env.merge("REDIS_URL" => "redis://127.0.0.1:6396/3"))
      end

      # redis-rb reads the database from the path only (?db= lands on db0);
      # redis-client honours the query. Under test the path form is required.
      def test_refuses_a_query_form_database_with_a_path_hint
        ["redis://127.0.0.1:6390?db=15", "redis://127.0.0.1:6390/?db=15", "rediss://10.0.0.5:6390/15?db=15"].each do |url|
          error = assert_raises(RedisEndpoint::Refused, url) { resolve({ "REDIS_URL" => url }) }
          assert_includes error.message, "in the path"
          refute_includes error.message, "6390"
        end
        assert_equal "redis://127.0.0.1:6390/15", resolve({ "REDIS_URL" => "redis://127.0.0.1:6390/15" })
      end

      # Every spelling that reaches this machine counts as local.
      def test_loopback_aliases_reach_the_static_rule
        ["localhost.", "127.1", "[::ffff:127.0.0.1]", "0.0.0.0", "[::]", "2130706433", Socket.gethostname].each do |host|
          assert_equal "loopback", RedisEndpoint.parse!("redis://#{host}:6379/0").location, host
        end
        assert_equal "10.200.0.5", RedisEndpoint.parse!("redis://10.200.0.5:6379/0").location
      end

      # Names are judged by the addresses they resolve to, not by their text.
      def test_names_resolving_to_this_machine_are_the_local_instance
        { "prod-alias.test" => [IPAddr.new("127.0.0.1")], "prod-v6.test" => [IPAddr.new("::1")],
          "prod-mapped.test" => [IPAddr.new("::ffff:127.0.0.1").native] }.each do |name, addresses|
          RedisEndpoint.stub(:host_addresses, addresses) do
            assert_equal "loopback", RedisEndpoint.parse!("redis://#{name}:6379/0").location, name
            assert_raises(RedisEndpoint::Refused, name) { resolve({ "REDIS_URL" => "redis://#{name}:6379/1" }) }
          end
        end
        RedisEndpoint.stub(:host_addresses, [IPAddr.new("10.20.30.40")]) do
          assert_equal "redis://remote-test.example:6379/0", resolve({ "REDIS_URL" => "redis://remote-test.example:6379/0" })
        end
        # Real resolutions on this machine: its own name and (when listed) ip6-localhost.
        assert_equal "loopback", RedisEndpoint.parse!("redis://#{Socket.gethostname}:6379/0").location
        assert_equal "loopback", RedisEndpoint.parse!("redis://ip6-localhost:6379/0").location if RedisEndpoint.host_addresses("ip6-localhost").any?
        address = local_interface_address
        assert_equal "loopback", RedisEndpoint.parse!("redis://#{address}:6379/0").location if address
      end

      def test_refuses_a_test_host_that_cannot_be_resolved
        RedisEndpoint.stub(:host_addresses, []) do
          error = assert_raises(RedisEndpoint::Refused) { resolve({ "REDIS_URL" => "redis://:pw@unknown-test.invalid:6390/15" }) }
          assert_includes error.message, "cannot be resolved"
          refute_includes error.message, "unknown-test"
          refute_includes error.message, "pw"
        end
      end

      # A production socket named in an env file is the same instance whatever
      # database a test URL adds (redis-rb ignores db for unix sockets).
      def test_production_socket_matches_regardless_of_database
        file = production_file("REDIS_URL=unix:///srv/prod-redis/redis.sock\n")
        env = { RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file }
        assert_raises(RedisEndpoint::Refused) { resolve(env.merge("REDIS_URL" => "unix:///srv/prod-redis/redis.sock?db=15")) }
        assert_equal "unix:///srv/other/redis.sock", resolve(env.merge("REDIS_URL" => "unix:///srv/other/redis.sock"))
      end

      # Inline comments and CRLF endings are parsed, query-form production
      # databases are compared under both client readings, and an unparseable
      # REDIS_*_URL refuses (naming the key and file, never the value).
      def test_production_file_inline_comments_query_forms_and_unparseable_values
        file = production_file("REDIS_URL=redis://127.0.0.1:6397/7 # note\r\nREDIS_CACHE_URL=\"redis://127.0.0.1:6398/2\" # c\n" \
                               "REDIS_SIDE_URL=redis://127.0.0.1:6399?db=4\n")
        expected = [["tcp", "loopback", 6397, 7], ["tcp", "loopback", 6398, 2], ["tcp", "loopback", 6399, 4], ["tcp", "loopback", 6399, 0]]
        assert_equal expected, RedisEndpoint.endpoints_in(file).map(&:to_a)
        env = { RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file }
        %w(redis://127.0.0.1:6397/7 redis://127.0.0.1:6398/2 redis://127.0.0.1:6399/4 redis://127.0.0.1:6399/0).each do |url|
          assert_raises(RedisEndpoint::Refused, url) { resolve(env.merge("REDIS_URL" => url)) }
        end

        broken = production_file("REDIS_URL=http://secret-host.invalid/0\n")
        error = assert_raises(RedisEndpoint::Refused) do
          resolve({ RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => broken, "REDIS_URL" => TEST_URL })
        end
        assert_includes error.message, "cannot be parsed"
        assert_includes error.message, "REDIS_URL"
        refute_includes error.message, "secret-host"
      end

      def test_socket_refusal_names_the_socket_rule
        error = assert_raises(RedisEndpoint::Refused) { resolve({ "REDIS_URL" => "unix:///run/redis/redis-server.sock" }) }
        assert_includes error.message, "system socket"
        refute_includes error.message, "port 6379"
        error = assert_raises(RedisEndpoint::Refused) { resolve({ "REDIS_URL" => "redis://127.0.0.1:6379/1" }) }
        assert_includes error.message, "local port 6379, db 0 or 1"
      end

      def test_compares_every_redis_url_assignment_in_the_production_file
        file = production_file("REDIS_CACHE_URL=redis://127.0.0.1:6391/4\n")
        env = { "REDIS_URL" => "redis://127.0.0.1:6391/4", RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file }
        assert_raises(RedisEndpoint::Refused) { resolve(env) }
      end

      def test_unreadable_production_file_is_skipped_without_error
        skip "root can read any file" if Process.uid.zero?

        file = production_file("REDIS_URL=redis://127.0.0.1:6392/5\n")
        File.chmod(0o000, file)
        env = { "REDIS_URL" => "redis://127.0.0.1:6392/5", RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file }
        assert_equal "redis://127.0.0.1:6392/5", resolve(env)
      end

      def test_default_production_file_cannot_be_removed_through_the_environment
        files = RedisEndpoint.production_env_files({ RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => "/tmp/a:/tmp/b" })
        defaults = ["/etc/mi-platform/runtime.env", "/home/deploy/decidim_app/.env"]
        assert_equal defaults + ["/tmp/a", "/tmp/b"], files
        assert_equal defaults, RedisEndpoint.production_env_files({})
      end

      def test_guard_covers_other_redis_urls_and_sidekiq_provider_indirection
        assert_raises(RedisEndpoint::Refused) do
          RedisEndpoint.guard_test_environment!({ "REDIS_URL" => TEST_URL, "REDIS_CACHE_URL" => "redis://127.0.0.1:6379/0" })
        end
        assert_raises(RedisEndpoint::Refused) do
          RedisEndpoint.guard_test_environment!({ "REDIS_URL" => TEST_URL, "REDIS_PROVIDER" => "OTHER_REDIS" })
        end
        assert RedisEndpoint.guard_test_environment!({ "REDIS_URL" => TEST_URL, "REDIS_PROVIDER" => "REDIS_URL", "REDIS_CACHE_URL" => "" })
        assert_raises(RedisEndpoint::Unconfigured) { RedisEndpoint.guard_test_environment!({}) }
      end

      # The rails_test helper must abort before the generated host boots and
      # before anything connects. The "production" endpoint here is a local
      # listener named by a fixture environment file; it must see no client.
      def test_rails_test_helper_aborts_before_boot_and_before_connecting
        server = TCPServer.new("127.0.0.1", 0)
        port = server.addr[1]
        file = production_file("REDIS_URL=redis://127.0.0.1:#{port}/0\n")
        cases = {
          "redis://127.0.0.1:#{port}/0" => "production Redis endpoint",
          "redis://127.0.0.1:6379/0" => "production Redis instance",
          "redis://localhost:6379/1" => "production Redis instance",
          nil => "explicit test Redis endpoint"
        }
        cases.each do |url, reason|
          env = base_env.merge(RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => file,
                               "DECIDIM_BIH_RAILS_APP" => File.join(@tmp, "missing-host"))
          env["REDIS_URL"] = url if url
          _out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(ROOT, "rails_test/test_helper.rb"),
                                             unsetenv_others: true)
          refute status.success?, url.inspect
          assert_includes err, "Refusing test Redis configuration", url.inspect
          assert_includes err, reason, url.inspect
          refute_includes err, "missing-host", "#{url.inspect} reached host boot"
        end
        assert_nil accept_pending(server), "a refused process connected to the production fixture"
      ensure
        server&.close
      end

      # Accepting a test endpoint must leave the harness process untouched: no
      # resolver or default gem (uri) may load before the host's Bundler setup.
      def test_rails_test_helper_accepts_a_test_endpoint_without_preloading_gems
        host = File.join(@tmp, "host")
        FileUtils.mkdir_p(File.join(host, "config"))
        # Stands in for the host's Bundler setup: nothing may be preloaded
        # before it, and it puts the engine's lib on the load path.
        File.write(File.join(host, "config/boot.rb"), <<~RUBY)
          preloaded = $LOADED_FEATURES.grep(%r{/(uri|ipaddr|redis_endpoint)\\.rb\\z})
          puts(preloaded.empty? ? "host boot reached cleanly" : "preloaded: \#{preloaded.join(",")}")
          $LOAD_PATH.unshift #{File.join(ROOT, "lib").inspect}
        RUBY
        # The host loads with the process already latched: a production
        # Rails.env cannot move the resolver off the test path.
        File.write(File.join(host, "config/environment.rb"), <<~'RUBY')
          module Rails
            def self.env = "production"
          end
          endpoint = Decidim::Bih::RedisEndpoint
          puts "latched=#{endpoint.test_process?}"
          puts "test url=#{endpoint.url}"
          begin
            endpoint.url(env: {})
            puts "unset url resolved"
          rescue endpoint::Unconfigured
            puts "unset refused"
          end
          exit 0
        RUBY
        helper = File.join(ROOT, "rails_test/test_helper.rb")
        env = base_env.merge("REDIS_URL" => TEST_URL, "DECIDIM_BIH_RAILS_APP" => host)
        out, err, status = Open3.capture3(env, RbConfig.ruby, helper, unsetenv_others: true)
        if installed_here?
          refute status.success?, out
          assert_includes err, "Redis guard refused this test environment"
        else
          assert status.success?, err
          assert_equal ["host boot reached cleanly", "latched=true", "test url=#{TEST_URL}", "unset refused"], out.lines.map(&:strip)
        end

        # Dedicated mode (plan item 7) through the same real entry point: the
        # instance is accepted, interim db15 and staging Redis are refused
        # before the host boots.
        dedicated = base_env.merge("MI_TEST_REDIS_URL_FILE" => dedicated_fixture, "DECIDIM_BIH_RAILS_APP" => host)
        out, err, status = Open3.capture3(dedicated.merge("REDIS_URL" => DEDICATED_URL), RbConfig.ruby, helper, unsetenv_others: true)
        assert status.success?, err
        assert_equal ["host boot reached cleanly", "latched=true", "test url=#{DEDICATED_URL}", "unset refused"], out.lines.map(&:strip)
        [TEST_URL, "redis://127.0.0.1:16379/0", "redis://192.0.2.10:16390/0"].each do |url|
          out, err, status = Open3.capture3(dedicated.merge("REDIS_URL" => url), RbConfig.ruby, helper, unsetenv_others: true)
          refute status.success?, url
          assert_includes err, "Redis guard refused this test environment", url
          refute_includes out, "host boot reached", url
        end
      end

      # A guard that cannot run is reported as a crash, still refuses to boot,
      # and an inherited RUBYOPT preload never reaches the guard child.
      def test_rails_test_helper_reports_a_crashed_guard_and_clears_rubyopt
        copy = File.join(@tmp, "engine")
        FileUtils.mkdir_p([File.join(copy, "rails_test"), File.join(copy, "lib/decidim/bih")])
        FileUtils.cp(File.join(ROOT, "rails_test/test_helper.rb"), File.join(copy, "rails_test/test_helper.rb"))
        File.write(File.join(copy, "lib/decidim/bih/redis_endpoint.rb"), "raise 'broken guard fixture'\n")
        marker = File.join(@tmp, "preload_marker.rb")
        File.write(marker, "warn 'preload marker loaded'\n")
        env = base_env.merge("REDIS_URL" => TEST_URL, "DECIDIM_BIH_RAILS_APP" => File.join(@tmp, "missing-host"),
                             "RUBYOPT" => "-r#{marker}")
        _out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(copy, "rails_test/test_helper.rb"), unsetenv_others: true)
        refute status.success?
        assert_includes err, "Redis guard check crashed"
        refute_includes err, "missing-host"
        assert_equal 1, err.scan("preload marker loaded").length, "RUBYOPT reached the guard child"

        _out, err, status = Open3.capture3(base_env.merge("REDIS_URL" => "redis://127.0.0.1:6379/0"), RbConfig.ruby,
                                           File.join(ROOT, "rails_test/test_helper.rb"), unsetenv_others: true)
        refute status.success?
        assert_includes err, "Redis guard refused this test environment"
        refute_includes err, "crashed"
      end

      def test_rails_harness_launcher_refuses_before_generating_a_host
        work_root = File.join(@tmp, "work")
        env = base_env.merge("REDIS_URL" => "redis://127.0.0.1:6379/1", "WORK_ROOT" => work_root,
                             "ENGINE_ROOT" => ROOT, "RBENV_ROOT" => File.join(@tmp, "no-rbenv"))
        _out, err, status = Open3.capture3(env, File.join(ROOT, "script/decidim_bih_rails_test"), unsetenv_others: true)
        assert_equal 64, status.exitstatus, err
        assert_includes err, "Refusing test Redis configuration"
        refute File.exist?(work_root), "launcher created a work root before refusing"

        # Dedicated mode: the interim db15 and another instance are refused too.
        [TEST_URL, "redis://127.0.0.1:16379/0"].each do |url|
          _out, err, status = Open3.capture3(env.merge("REDIS_URL" => url, "MI_TEST_REDIS_URL_FILE" => dedicated_fixture),
                                             File.join(ROOT, "script/decidim_bih_rails_test"), unsetenv_others: true)
          assert_equal 64, status.exitstatus, err
          assert_includes err, "Refusing test Redis configuration", url
          refute File.exist?(work_root), "launcher created a work root before refusing"
        end
      end

      # The launcher's guard child ignores an inherited RUBYOPT preload, and a
      # guard that cannot run is reported as a crash yet still stops the run.
      def test_rails_harness_launcher_clears_rubyopt_and_reports_a_crashed_guard
        marker = File.join(@tmp, "preload_marker.rb")
        File.write(marker, "warn 'preload marker loaded'\n")
        work_root = File.join(@tmp, "work")
        env = base_env.merge("REDIS_URL" => "redis://127.0.0.1:6379/0", "WORK_ROOT" => work_root, "ENGINE_ROOT" => ROOT,
                             "RBENV_ROOT" => File.join(@tmp, "no-rbenv"), "RUBYOPT" => "-r#{marker}")
        _out, err, status = Open3.capture3(env, File.join(ROOT, "script/decidim_bih_rails_test"), unsetenv_others: true)
        assert_equal 64, status.exitstatus, err
        assert_includes err, "Refusing test Redis configuration"
        refute_includes err, "preload marker loaded", "RUBYOPT reached the launcher's guard child"
        refute_includes err, "crashed"

        copy = File.join(@tmp, "engine")
        FileUtils.mkdir_p(File.join(copy, "lib/decidim/bih"))
        File.write(File.join(copy, "lib/decidim/bih/redis_endpoint.rb"), "raise 'broken guard fixture'\n")
        _out, err, status = Open3.capture3(env.merge("REDIS_URL" => TEST_URL, "ENGINE_ROOT" => copy),
                                           File.join(ROOT, "script/decidim_bih_rails_test"), unsetenv_others: true)
        assert_equal 64, status.exitstatus, err
        assert_includes err, "Redis guard check crashed"
        refute File.exist?(work_root), "launcher created a work root before refusing"
      end

      def test_engine_code_has_no_hardcoded_redis_fallback
        offenders = Dir[File.join(ROOT, "{app,lib,config}/**/*.rb")].select do |path|
          next false if path.end_with?("lib/decidim/bih/redis_endpoint.rb")

          File.read(path).match?(%r{REDIS_URL["']\s*,\s*["']redis://|redis://localhost:6379|redis://127\.0\.0\.1:6379})
        end
        assert_empty(offenders.map { |path| path.delete_prefix("#{ROOT}/") })
      end

      private

      def base_env
        { "PATH" => "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", "HOME" => @tmp, "RAILS_ENV" => "test", "LANG" => "C.UTF-8" }
      end

      # A non-loopback address of this machine, if it has one.
      def local_interface_address
        found = Socket.ip_address_list.find { |a| (a.ipv4? && !a.ipv4_loopback?) || (a.ipv6? && !a.ipv6_loopback? && !a.ipv6_linklocal?) }
        return unless found

        found.ipv6? ? "[#{found.ip_address}]" : found.ip_address
      end

      def accept_pending(server)
        server.accept_nonblock
      rescue IO::WaitReadable
        nil
      end
    end
  end
end

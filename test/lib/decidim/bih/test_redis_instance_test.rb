# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "decidim/bih/redis_endpoint"
require "ipaddr"
require "minitest/mock"

# -- standalone Minitest has no Rails assertion aliases
module Decidim
  module Bih
    class TestRedisInstanceTest < Minitest::Test
      SECRET = "fixture-secret-g7"
      DEDICATED = "redis://mi_test:#{SECRET}@127.0.0.1:16390/0".freeze
      OVERRIDE = TestRedisInstance::OVERRIDE_KEY
      ROOT = File.expand_path("../../../..", __dir__)

      def setup
        @tmp = Dir.mktmpdir("test-redis-instance")
        @absent = File.join(@tmp, "absent")
      end

      def teardown
        FileUtils.remove_entry(@tmp)
      end

      def install(url = DEDICATED, dir: File.join(@tmp, "etc"))
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "url"), "# fixture\n#{url}\n") if url
        dir
      end

      def interim(&)
        TestRedisInstance.with_install_dir(@absent, &)
      end

      def installed(url = DEDICATED, &)
        TestRedisInstance.with_install_dir(install(url), &)
      end

      def accepts(url, env = {})
        TestRedisInstance.assert_endpoint!(url, env:)
      end

      def refuses(url, env = {}, error: TestRedisInstance::Error)
        raised = assert_raises(error, url) { TestRedisInstance.assert_endpoint!(url, env:) }
        refute_includes raised.message, SECRET
        refute_includes raised.message, url
        raised
      end

      def test_interim_keeps_task_a_semantics_but_judges_where_the_url_lands
        interim do
          assert_nil TestRedisInstance.credential_url({})
          accepts("redis://127.0.0.1:6379/15")
          accepts("redis://127.0.0.1:16379/2")
          %w(redis://127.0.0.1:6379/0 redis://localhost:6379/1 redis://localhost.:6379/0 redis://127.1:6379/1
             redis://[::ffff:127.0.0.1]:6379/0 redis://[::1]:6379 redis://0.0.0.0:6379/1).each { |url| refuses(url) }
          interface = Socket.ip_address_list.find { |info| info.ipv4? && !info.ipv4_loopback? }
          refuses("redis://#{interface.ip_address}:6379/0") if interface
        end
      end

      def test_production_sockets_are_refused_in_any_mode_even_through_symlinks
        link = File.join(@tmp, "looks-harmless")
        File.symlink("/run/redis", link)
        interim do
          refuses("unix:///run/redis/redis-server.sock")
          refuses("unix:///var/run/redis/redis.sock?db=15")
          refuses("unix://#{link}/redis-server.sock")
        end
        installed { refuses("unix://#{link}/redis-server.sock") }
      end

      def test_installed_mode_accepts_only_the_credential_instance
        installed do
          assert_equal DEDICATED, TestRedisInstance.credential_url({})
          accepts(DEDICATED)
          accepts("redis://mi_test:#{SECRET}@127.0.0.1:16390/7")
          accepts("redis://mi_test:#{SECRET}@localhost:16390/0")
          assert_match(/dedicated test instance/, refuses("redis://127.0.0.1:6379/15").message)
          refuses("redis://localhost.:6379/15")
          assert_match(/not the dedicated test Redis instance/, refuses("redis://127.0.0.1:16379/0").message)
          refuses("redis://192.0.2.10:16390/0")
          refuses("redis://192.0.2.10:6379/0")
          refuses("unix://#{@tmp}/some.sock")
        end
      end

      def test_installed_but_unusable_credential_never_falls_back
        TestRedisInstance.with_install_dir(install(nil)) do
          assert_match(/missing or unreadable/, refuses("redis://127.0.0.1:6379/15", error: TestRedisInstance::Unavailable).message)
          refuses(DEDICATED, error: TestRedisInstance::Unavailable)
        end
        dir = install(nil, dir: File.join(@tmp, "linked"))
        File.write(File.join(@tmp, "real-url"), DEDICATED)
        File.symlink(File.join(@tmp, "real-url"), File.join(dir, "url"))
        TestRedisInstance.with_install_dir(dir) { refuses(DEDICATED, error: TestRedisInstance::Unavailable) }
      end

      def test_the_override_can_only_make_the_guard_stricter
        fixture = File.join(install(DEDICATED, dir: File.join(@tmp, "fixture")), "url")
        interim do
          # Not installed: an override forces dedicated mode with its file.
          assert TestRedisInstance.dedicated?(OVERRIDE => fixture)
          refuses("redis://127.0.0.1:6379/15", { OVERRIDE => fixture })
          accepts(DEDICATED, OVERRIDE => fixture)
          # A missing override file never means interim.
          refuses("redis://127.0.0.1:6379/15", { OVERRIDE => @absent }, error: TestRedisInstance::Unavailable)
        end
        installed do
          # Installed: pointing the override at nothing or elsewhere cannot reopen db15.
          refuses("redis://127.0.0.1:6379/15", { OVERRIDE => File.join(@absent, "url") }, error: TestRedisInstance::Unavailable)
          staging = File.join(install("redis://127.0.0.1:16379/0", dir: File.join(@tmp, "staging")), "url")
          assert_match(/another instance/, refuses("redis://127.0.0.1:16379/0", { OVERRIDE => staging }).message)
          accepts(DEDICATED, OVERRIDE => fixture)
        end
      end

      def test_a_credential_naming_production_or_another_machine_is_refused
        installed("redis://u:#{SECRET}@127.0.0.1:6379/15") { refuses(DEDICATED) }
        installed("redis://u:#{SECRET}@192.0.2.10:16390/0") { refuses(DEDICATED) }
        installed("redis://u:#{SECRET}@unresolvable-mi-test.invalid:16390/0") { refuses(DEDICATED) }
      end

      def test_redis_endpoint_shares_the_rule_for_every_client_and_entry_point
        fixture = File.join(install(DEDICATED, dir: File.join(@tmp, "fixture")), "url")
        env = { OVERRIDE => fixture }
        interim do
          assert_equal DEDICATED, RedisEndpoint.url(env: env.merge("REDIS_URL" => DEDICATED), rails_env: "test")
          error = assert_raises(RedisEndpoint::Refused) do
            RedisEndpoint.url(env: env.merge("REDIS_URL" => "redis://127.0.0.1:6379/15"), rails_env: "test")
          end
          refute_includes error.message, SECRET
          assert_raises(RedisEndpoint::Refused) do
            RedisEndpoint.guard_test_environment!(env.merge("REDIS_URL" => DEDICATED, "REDIS_CACHE_URL" => "redis://127.0.0.1:16379/0"))
          end
          assert RedisEndpoint.guard_test_environment!(env.merge("REDIS_URL" => DEDICATED))
        end
      end

      # Installed mode adds the instance rule; task A's rules still apply on
      # top: production spellings, the query-form database, unresolvable
      # names and the production environment file are all refused.
      def test_task_a_rules_still_hold_in_installed_mode
        prod_file = File.join(@tmp, "runtime.env")
        File.write(prod_file, "REDIS_URL=#{DEDICATED.sub("/0", "/3")}\n")
        installed do
          url = ->(value, extra = {}) { RedisEndpoint.url(env: { "REDIS_URL" => value }.merge(extra), rails_env: "test") }
          assert_equal DEDICATED, url.call(DEDICATED)
          %w(redis://127.0.0.1:6379/0 redis://localhost:6379/1 redis://127.1:6379/0 redis://[::ffff:127.0.0.1]:6379/0
             redis://127.0.0.1:6379/15 unix:///run/redis/redis-server.sock).each do |value|
            assert_raises(RedisEndpoint::Refused, value) { url.call(value) }
          end
          # A: database must be in the path; even the instance's own URL with ?db is refused.
          assert_raises(RedisEndpoint::Refused) { url.call("redis://mi_test:#{SECRET}@127.0.0.1:16390?db=3") }
          # A: an endpoint equal to a production environment file is refused, even on the instance.
          error = assert_raises(RedisEndpoint::Refused) do
            url.call(DEDICATED.sub("/0", "/3"), RedisEndpoint::EXTRA_PRODUCTION_ENV_FILES_KEY => prod_file)
          end
          refute_includes error.message, SECRET
          RedisEndpoint.stub(:host_addresses, []) do
            assert_raises(RedisEndpoint::Refused) { url.call("redis://mi_test:#{SECRET}@nowhere-g7.invalid:16390/0") }
          end
          # Names resolve through RedisEndpoint.host_addresses (one seam): a
          # name for the instance's address is the instance.
          RedisEndpoint.stub(:host_addresses, [IPAddr.new("127.0.0.1")]) do
            assert_equal "redis://mi_test:#{SECRET}@test-redis.g7:16390/1", url.call("redis://mi_test:#{SECRET}@test-redis.g7:16390/1")
          end
        end
      end

      # Production never reaches the instance rule: in a fresh, unlatched
      # interpreter with dedicated mode forced (fixture credential), resolution
      # is still byte-identical to ENV.fetch("REDIS_URL", <client default>).
      def test_production_resolution_is_unchanged
        fixture = File.join(install(DEDICATED, dir: File.join(@tmp, "fixture")), "url")
        probe = <<~RUBY
          require "decidim/bih/redis_endpoint"
          endpoint = Decidim::Bih::RedisEndpoint
          print [endpoint.test_process?, endpoint.url,
                 endpoint.url(fallback: endpoint::LOCAL_DB0_FALLBACK_URL)].join(" ")
        RUBY
        base = { "PATH" => "#{File.dirname(RbConfig.ruby)}:/usr/bin:/bin", "HOME" => @tmp, "LANG" => "C.UTF-8", OVERRIDE => fixture }
        {
          { "RAILS_ENV" => "production", "REDIS_URL" => "redis://127.0.0.1:6379/0" } =>
            "false redis://127.0.0.1:6379/0 redis://127.0.0.1:6379/0",
          { "RAILS_ENV" => "production" } =>
            "false #{RedisEndpoint::LEGACY_FALLBACK_URL} #{RedisEndpoint::LOCAL_DB0_FALLBACK_URL}",
          { "RAILS_ENV" => "development", "REDIS_URL" => "redis://127.0.0.1:6379/15" } =>
            "false redis://127.0.0.1:6379/15 redis://127.0.0.1:6379/15"
        }.each do |env, expected|
          out, err, status = Open3.capture3(base.merge(env), RbConfig.ruby, "--disable-gems", "-I", File.join(ROOT, "lib"),
                                            "-e", probe, unsetenv_others: true)
          assert status.success?, err
          assert_equal expected, out, env.inspect
        end
      end
    end
  end
end

# frozen_string_literal: true

require "uri"
require "ipaddr"
require "socket"
require_relative "test_redis_instance"

module Decidim
  module Bih
    # The one place that answers "which Redis does this process talk to".
    #
    # Outside the test environment nothing changes: REDIS_URL is returned
    # verbatim when it is set, and the historical local default is returned when
    # it is not. Under test the resolver FAILS CLOSED. Test processes once fell
    # back to redis://localhost:6379/1 and wrote into the production Redis
    # instance (production uses db0 on the same server; the engine fallback was
    # db1), so a test run must name an explicit, non-production endpoint.
    #
    # Pure Ruby with no Rails dependency, so test helpers can call
    # .guard_test_environment! before the application boots and before any
    # client opens a socket. Error messages never contain a URL, a credential
    # or the contents of a production environment file.
    module RedisEndpoint
      LEGACY_FALLBACK_URL = "redis://localhost:6379/1"
      # The historical production default of clients that fell back to db0
      # instead (the host's Milica ConversationUsage spend counters). Passed as
      # +fallback:+ so their production resolution stays byte-identical.
      LOCAL_DB0_FALLBACK_URL = "redis://127.0.0.1:6379/0"
      # Upper bound for resolving a host name in a test endpoint (hosts file or
      # DNS). Numeric addresses never resolve.
      RESOLVE_TIMEOUT = 2
      # Endpoints the production instance serves: the local default port with
      # db0 (Sidekiq, rack-attack, cache) and db1 (the old engine fallback).
      PRODUCTION_PORT = 6379
      PRODUCTION_DATABASES = [0, 1].freeze
      # Production environment files to compare against. Each is scanned line by
      # line for REDIS_*_URL assignments only -- never sourced, never printed,
      # and skipped when the current user cannot read it. The runtime copy is
      # root-only; the deploy-owned .env it is synchronised from lets the
      # comparison run in test processes started as deploy.
      PRODUCTION_ENV_FILES = %w(/etc/mi-platform/runtime.env /home/deploy/decidim_app/.env).freeze
      # Fixtures (and operators) may ADD files to compare against. The default
      # list can never be removed through the environment.
      EXTRA_PRODUCTION_ENV_FILES_KEY = "DECIDIM_BIH_PRODUCTION_ENV_FILES"
      # Debian's packaged instance listens on these socket directories.
      PRODUCTION_SOCKET_DIRECTORIES = %w(/run/redis /var/run/redis).freeze
      URL_KEY = /\AREDIS\w*_URL\z/

      class Error < StandardError; end

      class Unconfigured < Error; end

      class Refused < Error; end

      Endpoint = Struct.new(:transport, :location, :port, :database)

      module_function

      # Process-wide test identity. The host test/test_helper.rb and both engine
      # entry points (test/test_helper.rb, rails_test/test_helper.rb) latch it
      # before any test runs, and nothing clears it. Rails.env, RAILS_ENV and
      # RACK_ENV are mutable and tests stub them (Rails.env as "production" to
      # reach production-only branches); a latched process stays on the
      # fail-closed test path whatever they say. Production never latches, so
      # its resolution below is unchanged.
      def mark_test_process!
        @test_process = true
      end

      def test_process?
        @test_process == true
      end

      # The Redis URL a client should use. +rails_env+ defaults to the running
      # Rails environment (or RAILS_ENV/RACK_ENV before Rails has loaded). A
      # latched test process ignores it. +fallback+ is the client's historical
      # production default when REDIS_URL is unset; the test path never uses
      # any fallback.
      def url(env: ENV, rails_env: current_rails_env(env), fallback: LEGACY_FALLBACK_URL)
        return env.fetch("REDIS_URL", fallback) unless test_process? || rails_env.to_s == "test"

        configured = env["REDIS_URL"].to_s
        raise Unconfigured, "REDIS_URL must name an explicit test Redis endpoint under test" if configured.strip.empty?

        assert_test_endpoint!(configured, env:, name: "REDIS_URL")
        configured
      end

      # Boot guard for test helpers: aborts the process (via the raised error)
      # before Rails, Sidekiq or any store can open a connection. Covers
      # REDIS_URL (also Sidekiq's own default) and every other REDIS_*_URL.
      def guard_test_environment!(env = ENV)
        url(env:, rails_env: "test")
        provider = env["REDIS_PROVIDER"].to_s
        raise Refused, "REDIS_PROVIDER must be unset or REDIS_URL under test" unless provider.empty? || provider == "REDIS_URL"

        env.each_key do |key|
          next if key == "REDIS_URL" || !URL_KEY.match?(key) || env[key].to_s.strip.empty?

          assert_test_endpoint!(env[key], env:, name: key)
        end
        true
      end

      def assert_test_endpoint!(value, env: ENV, name: "REDIS_URL")
        endpoint = parse!(value, name)
        # redis-rb (every Redis.new store, Rails.cache, Rack::Attack) reads the
        # database from the path only and silently uses db0 for "?db=N", while
        # redis-client (Sidekiq) honours the query. One URL, two databases:
        # under test the database must be in the path.
        raise Refused, "#{name} must put the database in the path (/N), not in a db query parameter" if tcp_db_query?(value)
        raise Refused, production_instance_message(endpoint, name) if static_production?(endpoint)
        raise Refused, "#{name} host cannot be resolved, so it cannot be shown not to be the production instance" if unresolved_name?(endpoint)
        raise Refused, "#{name} equals a production Redis endpoint" if production_endpoints(env).any? { |prod| same_instance?(prod, endpoint) }

        # Where the URL lands, and once the dedicated test instance exists,
        # nothing but that instance (TestRedisInstance; plan item 7).
        begin
          TestRedisInstance.assert_endpoint!(value, env:, name:)
        rescue TestRedisInstance::Error => e
          raise Refused, e.message
        end
        endpoint
      end

      def tcp_db_query?(value)
        uri = URI.parse(value.to_s.strip)
        %w(redis rediss).include?(uri.scheme) && !query_database(uri).nil?
      rescue URI::Error, ArgumentError
        false
      end

      # redis-rb ignores the database (and credentials) of a unix:// URL, so a
      # socket is one instance whatever database it names.
      def same_instance?(production, endpoint)
        return production == endpoint unless endpoint.transport == "unix" || production.transport == "unix"

        production.transport == endpoint.transport && production.location == endpoint.location
      end

      def production_instance_message(endpoint, name)
        if endpoint.transport == "unix"
          "#{name} names the production Redis instance (system socket under #{PRODUCTION_SOCKET_DIRECTORIES.join(" or ")})"
        else
          "#{name} names the production Redis instance (local port #{PRODUCTION_PORT}, db 0 or 1)"
        end
      end

      def parse!(value, name = "REDIS_URL")
        uri = URI.parse(value.to_s.strip)
        case uri.scheme
        when "redis", "rediss"
          tcp_endpoint(uri, name)
        when "unix"
          path = uri.path.to_s
          raise Refused, "#{name} must name an absolute socket path" unless path.start_with?("/")

          Endpoint.new("unix", File.expand_path(path), nil, database_number!(query_database(uri), name))
        else
          raise Refused, "#{name} must use redis, rediss or unix"
        end
      rescue URI::Error, ArgumentError
        raise Refused, "#{name} is not a valid Redis URL"
      end

      def tcp_endpoint(uri, name)
        host = uri.host.to_s.delete_prefix("[").delete_suffix("]").downcase
        path = uri.path.to_s.delete_prefix("/")
        database = path.empty? ? query_database(uri) : path
        Endpoint.new("tcp", canonical_host(host), uri.port || PRODUCTION_PORT, database_number!(database, name))
      end

      def query_database(uri)
        URI.decode_www_form(uri.query.to_s).to_h.fetch("db", nil)
      end

      def database_number!(value, name)
        return 0 if value.nil? || value.to_s.empty?
        raise Refused, "#{name} database must be a nonnegative integer" unless value.to_s.match?(/\A\d+\z/)

        Integer(value.to_s, 10)
      end

      # Every spelling that reaches this machine is "loopback": localhost
      # (with or without a trailing dot), loopback/unspecified/IPv4-mapped
      # addresses, numeric shorthand such as 127.1 (parsed numerically, no DNS),
      # this host's own name and its interface addresses.
      def canonical_host(host)
        host = host.delete_suffix(".")
        return "loopback" if local_spelling?(host)

        address = numeric_address(host)
        if address
          address = address.native if address.ipv4_mapped?
          return local_address?(address) ? "loopback" : address.to_s
        end

        # A name is the endpoint it resolves to (hosts file or DNS): if any of
        # its addresses is this machine, it is this machine's Redis.
        host_addresses(host).any? { |candidate| local_address?(candidate) } ? "loopback" : host
      end

      def host_addresses(host)
        Addrinfo.getaddrinfo(host, nil, nil, :STREAM, nil, 0, timeout: RESOLVE_TIMEOUT).filter_map do |info|
          address = IPAddr.new(info.ip_address.split("%").first)
          address.ipv4_mapped? ? address.native : address
        rescue IPAddr::Error
          nil
        end.uniq
      rescue SocketError, SystemCallError, IOError
        []
      end

      def unresolved_name?(endpoint)
        endpoint.transport == "tcp" && endpoint.location != "loopback" && numeric_address(endpoint.location).nil? &&
          host_addresses(endpoint.location).empty?
      end

      def local_spelling?(host)
        host.empty? || host == "localhost" || host.end_with?(".localhost") || local_name?(host)
      end

      def numeric_address(host)
        IPAddr.new(host)
      rescue IPAddr::Error
        begin
          info = Addrinfo.getaddrinfo(host, nil, nil, :STREAM, nil, Socket::AI_NUMERICHOST).first
          info && IPAddr.new(info.ip_address)
        rescue SocketError, IPAddr::Error
          nil
        end
      end

      def local_address?(address)
        return true if address.loopback? || address.to_s == "0.0.0.0" || address.to_s == "::"

        Socket.ip_address_list.any? { |interface| IPAddr.new(interface.ip_address.split("%").first) == address }
      rescue SocketError, IPAddr::Error
        false
      end

      def local_name?(host)
        name = Socket.gethostname.to_s.downcase.delete_suffix(".")
        !name.empty? && (host == name || host == name.split(".").first)
      rescue SocketError, SystemCallError
        false
      end

      def static_production?(endpoint)
        if endpoint.transport == "unix"
          PRODUCTION_SOCKET_DIRECTORIES.any? { |directory| endpoint.location.start_with?("#{directory}/") }
        else
          endpoint.location == "loopback" && endpoint.port == PRODUCTION_PORT &&
            PRODUCTION_DATABASES.include?(endpoint.database)
        end
      end

      def production_endpoints(env = ENV)
        production_env_files(env).flat_map { |path| endpoints_in(path) }.uniq
      end

      def production_env_files(env = ENV)
        extra = env[EXTRA_PRODUCTION_ENV_FILES_KEY].to_s.split(":").reject(&:empty?)
        (PRODUCTION_ENV_FILES + extra).uniq
      end

      # Reads only REDIS_*_URL assignments, and only when the current user may
      # read the file. A matching assignment that cannot be parsed refuses the
      # test run (naming the file and key, never the value): a comparison that
      # silently skips a production endpoint would fail open.
      def endpoints_in(path)
        return [] unless File.file?(path) && File.readable?(path)

        # Binary read: no transcoding through Encoding.default_internal, and
        # invalid bytes elsewhere in the file cannot raise.
        File.foreach(path, mode: "rb").flat_map do |line|
          match = line.dup.force_encoding(Encoding::UTF_8).scrub.strip.match(/\A(?:export\s+)?(REDIS\w*_URL)\s*=\s*(.*)\z/)
          next [] unless match

          file_endpoints(assignment_value(match[2]), path, match[1])
        end
      rescue SystemCallError, IOError, EncodingError
        []
      end

      # The value of a dotenv/shell assignment: the quoted content, or the
      # unquoted text before an inline " #" comment.
      def assignment_value(raw)
        raw = raw.strip
        quoted = raw.match(/\A(["'])(.*?)\1/)
        return quoted[2] if quoted

        raw.sub(/\s+#.*\z/, "").strip
      end

      # Both readings of a production URL: path-or-query (redis-client) and
      # path-only (redis-rb), so a test URL matching either is refused.
      def file_endpoints(value, path, key)
        return [] if value.empty?

        endpoint = parse!(value, key)
        uri = URI.parse(value)
        return [endpoint] if endpoint.transport == "unix" || query_database(uri).nil?

        path_only = uri.path.to_s.delete_prefix("/")
        [endpoint, endpoint.dup.tap { |copy| copy.database = path_only.empty? ? 0 : database_number!(path_only, key) }].uniq
      rescue Refused, URI::Error
        raise Refused, "#{key} in production env file #{path} cannot be parsed; cannot compare the test endpoint"
      end

      def current_rails_env(env = ENV)
        if defined?(::Rails) && ::Rails.respond_to?(:env)
          rails_env = begin
            ::Rails.env
          rescue StandardError
            nil
          end
          return rails_env.to_s unless rails_env.to_s.empty?
        end
        value = env["RAILS_ENV"].to_s
        value.empty? ? env["RACK_ENV"].to_s : value
      end

      # A process that is a test process when this file first loads stays one:
      # every test entry point (rails test, the engine suites, standalone
      # contracts started with bundler/setup) loads the resolver under
      # RAILS_ENV/RACK_ENV=test before any test can stub those selectors.
      # Production processes load it under production and never latch.
      mark_test_process! if current_rails_env(ENV) == "test"
    end
  end
end

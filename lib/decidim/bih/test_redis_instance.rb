# frozen_string_literal: true

require "ipaddr"
require "socket"
require "uri"

module Decidim
  module Bih
    # Instance-level, mode-aware judgement of a TEST Redis endpoint
    # (server-health plan item 7). RedisEndpoint.assert_test_endpoint! calls
    # this for every REDIS_*_URL a test process uses, so every client and every
    # test entry point (host test_helper, engine suites, generated hosts, smoke
    # scripts) shares one rule. Production resolution never reaches this code.
    #
    # Two modes, decided by the FILESYSTEM, never by the environment:
    #
    # * interim -- /etc/mi-test-redis does not exist. Tests may use any endpoint
    #   that is not production Redis db0/db1 or a production socket; the
    #   launchers hand out db15 on the production instance meanwhile.
    # * dedicated -- /etc/mi-test-redis exists (the install creates it last).
    #   Every REDIS_*_URL must land on exactly the instance named by the
    #   credential file /etc/mi-test-redis/url (transport, address, port; the
    #   database may differ). The production instance, staging Redis and any
    #   remote host are refused. A credential this process cannot read refuses.
    #
    # MI_TEST_REDIS_URL_FILE can only make things stricter: it forces dedicated
    # mode with another credential file (fixtures), and once the canonical
    # directory exists it must name the same instance as the canonical file.
    # No environment variable selects interim mode. In-process tests that need
    # interim semantics use .with_install_dir, which the environment cannot reach.
    #
    # "Production instance" means where a URL lands, not how it is spelled: host
    # names are resolved, port 6379 on any address of this machine (loopback,
    # unspecified, IPv4-mapped, interface addresses) is production, and socket
    # paths are compared after resolving symlinks. Pure Ruby standard library.
    # Messages never contain a URL, a credential or file contents.
    module TestRedisInstance
      INSTALL_DIR = "/etc/mi-test-redis"
      OVERRIDE_KEY = "MI_TEST_REDIS_URL_FILE"
      PRODUCTION_PORT = 6379
      PRODUCTION_DATABASES = [0, 1].freeze
      PRODUCTION_SOCKET_DIRECTORIES = %w(/run/redis /var/run/redis).freeze
      RESOLVE_TIMEOUT = 2

      class Error < StandardError; end

      class Refused < Error; end

      class Unavailable < Error; end

      Endpoint = Struct.new(:transport, :host, :port, :path, :database)

      module_function

      def install_dir
        @install_dir || INSTALL_DIR
      end

      # Test seam, Ruby only: run a block as if the canonical directory were
      # +path+. Never reachable through ENV.
      def with_install_dir(path)
        previous = @install_dir
        @install_dir = path
        yield
      ensure
        @install_dir = previous
      end

      def installed?
        File.directory?(install_dir)
      end

      def dedicated?(env = ENV)
        installed? || !env[OVERRIDE_KEY].to_s.empty?
      end

      # The dedicated credential URL, or nil in interim mode. Raises when the
      # dedicated credential cannot be used.
      def credential_url(env = ENV)
        override = env[OVERRIDE_KEY].to_s
        canonical = read_credential(File.join(install_dir, "url")) if installed?
        return canonical if override.empty?

        alternate = read_credential(override)
        if canonical && !same_instance?(parse!(canonical, "credential"), parse!(alternate, OVERRIDE_KEY))
          raise Refused, "#{OVERRIDE_KEY} names another instance than the installed test Redis"
        end

        alternate
      end

      def read_credential(path) # rubocop:disable Metrics/CyclomaticComplexity
        raise Unavailable, "the test Redis credential file must not be a symlink" if File.symlink?(path)

        unless File.file?(path) && File.readable?(path)
          raise Unavailable, "the dedicated test Redis credential is missing or unreadable for this process " \
                             "(test processes run as deploy in group mi-test-redis)"
        end

        value = File.foreach(path).map(&:strip).reject { |line| line.empty? || line.start_with?("#") }.first.to_s
        endpoint = parse!(value, "the test Redis credential")
        raise Refused, "the test Redis credential names the production Redis instance" if production_instance?(endpoint)
        raise Refused, "the test Redis credential must name an endpoint on this machine" unless local_endpoint?(endpoint)

        value
      rescue SystemCallError, IOError
        raise Unavailable, "the test Redis credential file cannot be read"
      end

      def assert_endpoint!(value, env: ENV, name: "REDIS_URL")
        endpoint = parse!(value, name)
        credential = credential_url(env)
        if production_instance?(endpoint) && (credential || endpoint.transport == "unix" ||
                                              PRODUCTION_DATABASES.include?(endpoint.database))
          # Interim mode allows db2-15 on the production TCP port, never its
          # sockets: redis-rb ignores the database of a unix:// URL (db0).
          raise Refused, "#{name} reaches the production Redis instance" \
                         "#{credential ? "; tests use the dedicated test instance" : " (db 0/1 or its socket)"}"
        end
        raise Refused, "#{name} is not the dedicated test Redis instance" if credential && !same_instance?(endpoint, parse!(credential, "the test Redis credential"))

        endpoint
      end

      def parse!(value, name)
        uri = URI.parse(value.to_s.strip)
        case uri.scheme
        when "redis", "rediss"
          host = uri.host.to_s.delete_prefix("[").delete_suffix("]")
          path = uri.path.to_s.delete_prefix("/")
          Endpoint.new("tcp", host.empty? ? "localhost" : host, uri.port || PRODUCTION_PORT, nil,
                       database!(path.empty? ? query_database(uri) : path, name))
        when "unix"
          raise Refused, "#{name} must name an absolute socket path" unless uri.path.to_s.start_with?("/")

          Endpoint.new("unix", nil, nil, real_path(uri.path), database!(query_database(uri), name))
        else
          raise Refused, "#{name} must use redis, rediss or unix"
        end
      rescue URI::Error, ArgumentError
        raise Refused, "#{name} is not a valid Redis URL"
      end

      def query_database(uri)
        URI.decode_www_form(uri.query.to_s).to_h.fetch("db", nil)
      end

      def database!(value, name)
        return 0 if value.nil? || value.to_s.empty?
        raise Refused, "#{name} database must be a nonnegative integer" unless value.to_s.match?(/\A\d+\z/)

        Integer(value.to_s, 10)
      end

      # Same server: transport, port and at least one shared address (TCP), or
      # the same real socket path. The database is not part of the identity.
      def same_instance?(left, right)
        return false unless left.transport == right.transport
        return left.path == right.path if left.transport == "unix"

        left.port == right.port && addresses(left.host).intersect?(addresses(right.host))
      end

      def production_instance?(endpoint)
        if endpoint.transport == "unix"
          PRODUCTION_SOCKET_DIRECTORIES.flat_map { |dir| [dir, real_path(dir)] }.uniq.any? do |dir|
            endpoint.path.start_with?("#{dir}/")
          end
        else
          endpoint.port == PRODUCTION_PORT && local_host?(endpoint.host)
        end
      end

      def local_endpoint?(endpoint)
        endpoint.transport == "unix" || local_host?(endpoint.host)
      end

      def local_host?(host)
        addresses(host).any? { |address| local_address?(address) }
      end

      # Resolved, normalised addresses (IPv4-mapped become IPv4). Literal and
      # numeric forms (127.1, 2130706433) resolve without a lookup; names go
      # through RedisEndpoint.host_addresses, the one name-resolution seam the
      # static rules use too. Unresolvable names fail closed: the guard cannot
      # tell where they land.
      def addresses(host)
        literal = host.split("%", 2).first
        list = if ip_literal?(literal)
                 [IPAddr.new(literal)]
               else
                 numeric = numeric_address(literal)
                 numeric ? [numeric] : name_addresses(host)
               end
        list = list.map { |address| address.ipv4_mapped? ? address.native : address }.uniq
        raise Refused, "a Redis host name could not be resolved" if list.empty?

        list
      rescue IPAddr::Error
        raise Refused, "a Redis host name could not be resolved"
      end

      def numeric_address(host)
        info = Addrinfo.getaddrinfo(host, nil, nil, :STREAM, nil, Socket::AI_NUMERICHOST).first
        info && IPAddr.new(info.ip_address.split("%", 2).first)
      rescue SocketError, IPAddr::Error
        nil
      end

      def name_addresses(host)
        return Decidim::Bih::RedisEndpoint.host_addresses(host) if defined?(Decidim::Bih::RedisEndpoint.host_addresses)

        Addrinfo.getaddrinfo(host, nil, nil, :STREAM, nil, 0, timeout: RESOLVE_TIMEOUT)
                .map { |info| IPAddr.new(info.ip_address.split("%", 2).first) }
      rescue SocketError, SystemCallError, IOError
        []
      end

      def ip_literal?(value)
        IPAddr.new(value)
        true
      rescue IPAddr::Error
        false
      end

      def local_address?(address)
        return true if address.loopback? || ["0.0.0.0", "::"].include?(address.to_s)

        Socket.ip_address_list.any? do |info|
          IPAddr.new(info.ip_address.split("%", 2).first) == address
        rescue IPAddr::Error
          false
        end
      end

      # Resolves every symlink on the path, dangling ones included, so a link
      # into /run/redis is recognised even while nothing listens there.
      def real_path(path, depth = 0)
        path = File.expand_path(path)
        return path if depth > 16

        suffix = []
        current = path
        until current == "/"
          if File.symlink?(current)
            target = File.expand_path(File.readlink(current), File.dirname(current))
            return real_path(File.join(target, *suffix), depth + 1)
          end
          break if File.exist?(current)

          suffix.unshift(File.basename(current))
          current = File.dirname(current)
        end
        File.join(File.realpath(current), *suffix)
      rescue SystemCallError
        path
      end
    end
  end
end

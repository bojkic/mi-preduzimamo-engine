# frozen_string_literal: true

module Decidim
  module Bih
    # Compatibility mitigation for rack-proxy 0.8.3 only. The package advisory
    # confirms 1.x, and explicitly leaves older versions unassessed. This guard
    # addresses the observed framing mechanism; it is not an exploitability claim.
    module RackProxyResponseGuard
      class AmbiguousResponse < StandardError; end

      module ProxyCall
        def call(env)
          super
        rescue RackProxyResponseGuard::AmbiguousResponse
          [502, {}, []]
        end
      end

      module ResponseHeaders
        def normalize_headers(headers)
          RackProxyResponseGuard.reject_ambiguous!(headers)
          result = super
          connection_names = result.each_with_object([]) do |(key, value), names|
            names.concat(Array(value).flat_map { |part| part.to_s.downcase.split(/[,\n]/).map(&:strip) }) if key.downcase == "connection"
          end
          result.keys.each do |key|
            result.delete(key) if Rack::Proxy::HOP_BY_HOP_HEADERS[key.downcase] || connection_names.include?(key.downcase)
          end
          result
        end
      end

      module StreamingHeaders
        def headers
          value = super
          return value unless RackProxyResponseGuard.ambiguous?(value)

          # Do not call 0.8.3 close_connection: end_request_hacked drains the
          # rejected response body. Close only the already-created HTTP session;
          # never invoke the lazy session accessor or replay the request.
          self.connection_closed = true
          begin
            @session.finish if @session && @session.started?
          rescue IOError, SystemCallError
            # Teardown failure cannot make rejected bytes eligible for delivery.
          end
          raise RackProxyResponseGuard::AmbiguousResponse, "Ambiguous backend response framing"
        end
      end

      def self.ambiguous?(headers)
        names = headers.map { |key, _| key.to_s.downcase }
        names.include?("transfer-encoding") && names.include?("content-length")
      end

      def self.reject_ambiguous!(headers)
        raise AmbiguousResponse, "Ambiguous backend response framing" if ambiguous?(headers)
      end

      def self.install!
        return false unless Gem.loaded_specs["rack-proxy"]&.version&.to_s == "0.8.3"

        require "rack/proxy"
        Rack::Proxy.prepend(ProxyCall) unless Rack::Proxy < ProxyCall
        Rack::Proxy.singleton_class.prepend(ResponseHeaders) unless Rack::Proxy.singleton_class < ResponseHeaders
        Rack::HttpStreamingResponse.prepend(StreamingHeaders) unless Rack::HttpStreamingResponse < StreamingHeaders
        true
      end
    end
  end
end

# frozen_string_literal: true

require "faraday"
require "uri"
require "resolv"
require "stringio"

module Decidim
  module Bih
    module Viber
      # Downloads an inbound Viber/Infobip image (the temporary, ~1h-TTL CDN URL
      # exposed by Decidim::Bih::Viber::InboundMessage#image_url) into an
      # in-memory attachable the ReportIntake can hand to ActiveStorage.
      #
      # SECURITY: the URL is ATTACKER-INFLUENCED — it arrives over the public
      # Viber channel webhook. This fetcher is therefore an SSRF chokepoint and
      # is deliberately paranoid:
      #
      #   * only http/https schemes;
      #   * the host must end in one of an ALLOWLIST of Viber/Infobip CDN host
      #     suffixes (overridable via ENV VIBER_IMAGE_HOST_ALLOWLIST, a comma
      #     list) — everything else is refused;
      #   * embedded credentials (userinfo@) and IP-literal hosts are refused
      #     outright (classic SSRF bypass vectors);
      #   * the download is capped DURING the read (#MAX_BYTES) and aborted the
      #     moment it is exceeded, so a hostile/huge body cannot exhaust memory;
      #   * the response Content-Type must be an allowed image type;
      #   * redirects are NOT followed (the default Faraday stack adds no
      #     redirect middleware), so a 3xx to an internal host degrades to nil.
      #
      # It NEVER raises into the report flow: any problem (refused URL, transport
      # error, oversized/!image body, parse error) returns nil and logs a warning
      # so a report is still filed, just without the photo.
      class ImageFetcher
        # Short bound on both connect and read — the CDN is fast and we are on a
        # synchronous webhook path.
        DEFAULT_TIMEOUT = 5

        # Hard cap on the downloaded body, enforced incrementally during read.
        # Matches Report::PHOTO_MAX_BYTES (5MB) so anything the fetcher accepts
        # also passes the model — a larger ceiling here would only let through
        # photos the report then rejects.
        MAX_BYTES = 5 * 1024 * 1024

        # Content-Type allowlist (mirrors Report::PHOTO_CONTENT_TYPES). SVG is
        # intentionally excluded.
        ALLOWED_CONTENT_TYPES = %w(image/png image/jpeg image/webp).freeze

        # Default CDN host suffixes considered safe to fetch from. Overridden
        # wholesale by ENV VIBER_IMAGE_HOST_ALLOWLIST when present. NOTE: a bare
        # shared-CDN suffix (e.g. akamaihd.net) is deliberately NOT included — it
        # would admit any Akamai customer; set the exact Viber/Infobip media host
        # via VIBER_IMAGE_HOST_ALLOWLIST once confirmed from a real inbound payload.
        DEFAULT_HOST_ALLOWLIST = %w(viber.com cdn.viber.com infobip.com).freeze

        # Filename used when the URL path carries no usable basename.
        DEFAULT_BASENAME = "viber_image"

        # Maps an allowed content type to the extension used for the default
        # filename.
        EXTENSION_FOR = { "image/png" => ".png", "image/jpeg" => ".jpg", "image/webp" => ".webp" }.freeze

        # Raised internally when the body exceeds MAX_BYTES mid-read; caught and
        # converted to nil like any other failure.
        class DownloadTooLarge < StandardError; end

        def initialize(timeout: DEFAULT_TIMEOUT, host_allowlist: self.class.default_host_allowlist)
          @timeout = timeout
          @host_allowlist = host_allowlist
        end

        # Comma-separated ENV override, falling back to the built-in defaults.
        def self.default_host_allowlist
          raw = ENV.fetch("VIBER_IMAGE_HOST_ALLOWLIST", nil)
          return DEFAULT_HOST_ALLOWLIST if raw.blank?

          raw.split(",").map { |host| host.strip.downcase }.reject(&:empty?)
        end

        # Returns an ActiveStorage attachable Hash
        # { io:, filename:, content_type: } on success, or nil on ANY problem.
        def call(url)
          uri = safe_uri(url)
          return nil unless uri

          download(uri)
        rescue StandardError => e
          warn_fetch(url, e.message)
          nil
        end

        private

        attr_reader :timeout, :host_allowlist

        # Parses + vets the URL against the SSRF policy. Returns a URI on success
        # or nil (logging why) on any rejection.
        def safe_uri(url)
          return reject(url, "blank url") if url.blank?

          uri = URI.parse(url.to_s)
          return reject(url, "scheme not http(s)") unless uri.is_a?(URI::HTTP)
          return reject(url, "embedded userinfo") if uri.userinfo.present?

          host = uri.host.to_s.downcase
          return reject(url, "blank host") if host.empty?
          return reject(url, "ip-literal host") if ip_literal?(host)
          return reject(url, "host not allowlisted") unless host_allowed?(host)

          uri
        rescue URI::InvalidURIError => e
          reject(url, "unparseable url (#{e.message})")
        end

        # A host is allowed when it equals, or is a subdomain of, an allowlisted
        # suffix. "evilviber.com" does NOT match "viber.com".
        def host_allowed?(host)
          host_allowlist.any? { |suffix| host == suffix || host.end_with?(".#{suffix}") }
        end

        # True for bare IPv4/IPv6 literals (incl. bracketed IPv6). IP hosts skip
        # DNS and are a common SSRF bypass, so they are always refused.
        def ip_literal?(host)
          stripped = host.delete("[]")
          stripped.match?(Resolv::IPv4::Regex) || stripped.match?(Resolv::IPv6::Regex)
        end

        # Streams the body into memory, aborting the instant the size cap is
        # exceeded, then validates status + content type.
        def download(uri)
          buffer = +""
          response = connection.get(uri.to_s) do |req|
            req.options.on_data = proc do |chunk, _overall|
              buffer << chunk
              raise DownloadTooLarge if buffer.bytesize > MAX_BYTES
            end
          end

          return reject(uri, "http #{response.status}") unless response.success?

          content_type = normalize_content_type(response.headers["content-type"])
          return reject(uri, "content-type #{content_type.inspect}") unless ALLOWED_CONTENT_TYPES.include?(content_type)
          return reject(uri, "empty body") if buffer.empty?

          Decidim::Bih::Media::ImageNormalizer.call(
            io: StringIO.new(buffer),
            filename: filename_for(uri, content_type),
            content_type: content_type
          )
        end

        # Strips any "; charset=..." parameter and downcases.
        def normalize_content_type(value)
          value.to_s.split(";").first.to_s.strip.downcase
        end

        # Prefers the URL path's basename when it already carries an extension;
        # otherwise a stable default with the content-type's extension.
        def filename_for(uri, content_type)
          base = File.basename(uri.path.to_s)
          base = nil if base.blank? || base == "/" || base == "."
          return base if base&.match?(/\.\w+\z/)

          "#{DEFAULT_BASENAME}#{EXTENSION_FOR.fetch(content_type, "")}"
        end

        def connection
          @connection ||= Faraday.new do |conn|
            conn.options.timeout = timeout
            conn.options.open_timeout = timeout
            conn.adapter Faraday.default_adapter
          end
        end

        # Logs a rejection reason and returns nil so callers can `return reject(...)`.
        def reject(url, reason)
          warn_fetch(url, reason)
          nil
        end

        def warn_fetch(url, reason)
          safe_url = url_for_log(url)
          Rails.logger.warn("[Viber::ImageFetcher] refused/failed for #{safe_url}: #{reason_for_log(reason, url, safe_url)}")
        end

        def url_for_log(url)
          raw = url.to_s
          return "[blank]" if raw.blank?

          uri = URI.parse(raw)
          uri.user = nil if uri.respond_to?(:user=)
          uri.password = nil if uri.respond_to?(:password=)
          uri.query = nil if uri.respond_to?(:query=)
          uri.fragment = nil if uri.respond_to?(:fragment=)
          uri.to_s
        rescue URI::InvalidURIError
          raw.split(/[?#]/, 2).first.presence || "[unparseable url]"
        end

        def reason_for_log(reason, url, safe_url)
          text = reason.to_s
          [url.to_s, url.to_s.split("#", 2).first].reject(&:blank?).uniq.each do |candidate|
            text = text.gsub(candidate, safe_url)
          end

          text
            .gsub(%r{(https?://[^\s?#]+)\?[^\s]*}, "\\1")
            .gsub(%r{(https?://[^\s#]+)#[^\s]*}, "\\1")
        end
      end
    end
  end
end

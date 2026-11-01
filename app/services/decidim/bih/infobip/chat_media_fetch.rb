# frozen_string_literal: true

require "faraday"
require "resolv"
require "stringio"
require "uri"

module Decidim
  module Bih
    module Infobip
      # Downloads one inbound chat photo (the short-lived provider media URL
      # exposed by Decidim::Bih::Infobip::InboundMessage#image_url) into an
      # in-memory attachable the report intake can hand to ActiveStorage.
      #
      # Unlike Decidim::Bih::Viber::ImageFetcher — which collapses every problem
      # into nil because the Viber bot files the report anyway — this fetcher
      # returns a Result carrying WHY it refused, so the chat adapter can answer
      # the citizen with an honest sentence instead of silently dropping the
      # photo. It never raises into the conversation.
      #
      # SECURITY: the URL is ATTACKER-INFLUENCED (it arrives on a public webhook)
      # and this is therefore an SSRF chokepoint:
      #
      #   * https only (a provider media URL is always https);
      #   * the host must equal, or be a subdomain of, an allowlisted suffix
      #     (ENV INFOBIP_MEDIA_HOST_ALLOWLIST overrides DEFAULT_HOST_ALLOWLIST
      #     wholesale, and the configured Infobip account host is always
      #     allowed);
      #   * embedded credentials (userinfo@) and IP-literal hosts are refused;
      #   * at most ONE redirect is followed, and the redirect target is vetted
      #     by exactly the same policy as the original URL;
      #   * the body is capped DURING the read (MAX_BYTES) and the download is
      #     abandoned the instant the cap is passed;
      #   * the response Content-Type must be on the allow list.
      #
      # PRIVACY: neither the URL nor any downloaded byte is ever logged. Log
      # lines carry the refusal reason only — a media URL is a bearer token for
      # a citizen's photo, and an image body is the citizen's own content.
      #
      # HEIC is deliberately NOT accepted: this platform stores what the citizen
      # sent (Decidim::Bih::Media::ImageNormalizer only strips metadata, it does
      # not transcode) and Report::PHOTO_CONTENT_TYPES has no HEIC entry, so an
      # accepted HEIC would be rejected again by the model at attach time.
      class ChatMediaFetch
        # Bounded connect + read. The brief's ceiling is 10s and the provider
        # CDN is fast; this runs on a webhook path that must answer quickly.
        DEFAULT_TIMEOUT = 8

        # Hard cap on the downloaded body. Mirrors Report::PHOTO_MAX_BYTES (5MB)
        # rather than the brief's 8MB ceiling: a larger ceiling here would only
        # admit photos the report model then refuses, turning a kind refusal
        # into a confusing "accepted, then vanished".
        MAX_BYTES = 5 * 1024 * 1024

        # Mirrors Report::PHOTO_CONTENT_TYPES. SVG is excluded on purpose
        # (inline XSS through the blob URL forwarded to Sistem 48).
        ALLOWED_CONTENT_TYPES = %w(image/png image/jpeg image/webp).freeze

        # Host suffixes considered safe to fetch provider media from. A bare
        # shared-CDN suffix is deliberately absent: it would admit every
        # customer of that CDN. Override wholesale with a comma list in
        # INFOBIP_MEDIA_HOST_ALLOWLIST once a real inbound payload confirms the
        # media host of each channel.
        DEFAULT_HOST_ALLOWLIST = %w(infobip.com api.infobip.com).freeze

        MAX_REDIRECTS = 1
        REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze
        # 410 Gone is the provider saying the media reference has expired, which
        # is a different sentence to the citizen from "the download failed": the
        # photo is gone for good and must be resent. Every other non-2xx — 404
        # included, since "not found" can just as easily be a bad reference — is
        # reported as a fetch failure.
        EXPIRED_STATUSES = [410].freeze

        DEFAULT_BASENAME = "chat_photo"
        EXTENSION_FOR = { "image/png" => ".png", "image/jpeg" => ".jpg", "image/webp" => ".webp" }.freeze

        # status is one of:
        #   :ok            — attachable is a { io:, filename:, content_type: } Hash
        #   :none          — no media reference at all (nothing to do, no error)
        #   :too_large     — body over MAX_BYTES (or declared so by Content-Length)
        #   :invalid_type  — Content-Type off the allow list, or unreadable bytes
        #   :expired       — the provider no longer serves this media reference
        #   :failed        — refused URL, transport error, or any other status
        Result = Data.define(:status, :attachable, :content_type, :byte_size) do
          def ok? = status == :ok

          def refused? = [:ok, :none].exclude?(status)
        end

        # Raised internally the moment the body passes MAX_BYTES.
        DownloadTooLarge = Class.new(StandardError)

        class << self
          def call(url, **) = new(**).call(url)

          # Comma-separated ENV override, else the built-in defaults.
          def default_host_allowlist
            raw = ENV.fetch("INFOBIP_MEDIA_HOST_ALLOWLIST", nil)
            return DEFAULT_HOST_ALLOWLIST if raw.nil? || raw.to_s.strip.empty?

            raw.to_s.split(",").map { |host| host.strip.downcase }.reject(&:empty?)
          end
        end

        def initialize(timeout: DEFAULT_TIMEOUT,
                       max_bytes: MAX_BYTES,
                       host_allowlist: self.class.default_host_allowlist,
                       client: nil,
                       transport: nil)
          @timeout = timeout
          @max_bytes = max_bytes
          @host_allowlist = host_allowlist
          @client = client
          @transport = transport
        end

        def call(url)
          return result(:none) if url.nil? || url.to_s.strip.empty?

          uri = safe_uri(url)
          return refuse(:failed, "url refused by policy") unless uri

          fetch(uri, redirects_left: MAX_REDIRECTS)
        rescue DownloadTooLarge
          refuse(:too_large, "body over cap")
        rescue StandardError => e
          refuse(:failed, e.class.to_s)
        end

        private

        attr_reader :timeout, :max_bytes, :host_allowlist, :transport

        def fetch(uri, redirects_left:)
          response = perform(uri)
          return refuse(:too_large, "declared length over cap") if response.truncated

          if REDIRECT_STATUSES.include?(response.status)
            return refuse(:failed, "redirect budget exhausted") unless redirects_left.positive?

            target = redirect_target(uri, response)
            return refuse(:failed, "redirect refused") unless target

            return fetch(target, redirects_left: redirects_left - 1)
          end

          return refuse(:expired, "http #{response.status}") if EXPIRED_STATUSES.include?(response.status)
          return refuse(:failed, "http #{response.status}") unless response.status.between?(200, 299)

          build(response)
        end

        def build(response)
          body = response.body.to_s
          return refuse(:too_large, "body over cap") if body.bytesize > max_bytes
          return refuse(:failed, "empty body") if body.empty?

          content_type = normalize_content_type(header(response, "content-type"))
          return refuse(:invalid_type, "content-type off the allow list") unless ALLOWED_CONTENT_TYPES.include?(content_type)

          # Strips EXIF/GPS before the bytes are ever stored, so a pending photo
          # never parks the citizen's device metadata anywhere.
          attachable = Decidim::Bih::Media::ImageNormalizer.call(
            io: StringIO.new(body), filename: filename_for(content_type), content_type:
          )
          return refuse(:invalid_type, "image could not be normalized") unless attachable

          result(:ok, attachable:, content_type:, byte_size: body.bytesize)
        end

        # Only an absolute https target on an allowlisted host is followed, and
        # it is re-vetted by the same policy as the original URL.
        def redirect_target(uri, response)
          location = header(response, "location").to_s.strip
          return if location.empty?

          safe_uri(URI.join(uri.to_s, location).to_s)
        rescue URI::InvalidURIError, ArgumentError
          nil
        end

        def safe_uri(url)
          uri = URI.parse(url.to_s)
          return unless uri.is_a?(URI::HTTPS)
          return if uri.userinfo.present?

          host = uri.host.to_s.downcase
          return if host.empty? || ip_literal?(host) || !host_allowed?(host)

          uri
        rescue URI::InvalidURIError
          nil
        end

        def host_allowed?(host)
          allowlist = host_allowlist + [account_host].compact
          allowlist.any? { |suffix| host == suffix || host.end_with?(".#{suffix}") }
        end

        # The configured Infobip account host is always fetchable: it is where
        # this deployment's own provider media lives.
        def account_host
          @account_host ||= begin
            base = Decidim::Bih::Config.infobip[:base_url]
            URI.parse(base.to_s).host&.downcase if base.to_s.strip != ""
          rescue StandardError
            nil
          end
        end

        def ip_literal?(host)
          stripped = host.delete("[]")
          stripped.match?(Resolv::IPv4::Regex) || stripped.match?(Resolv::IPv6::Regex)
        end

        Response = Data.define(:status, :headers, :body, :truncated)

        def perform(uri)
          return transport.call(url: uri.to_s, headers: request_headers(uri), timeout:, max_bytes:) if transport

          buffer = +""
          response = connection.get(uri.to_s) do |request|
            request_headers(uri).each { |name, value| request.headers[name] = value }
            request.options.on_data = proc do |chunk, _overall|
              buffer << chunk.to_s
              raise DownloadTooLarge if buffer.bytesize > max_bytes
            end
          end
          Response.new(status: response.status, headers: response.headers.to_h, body: buffer, truncated: false)
        rescue DownloadTooLarge
          # Faraday may surface the abort wrapped; either way the body is over
          # the cap and the partially buffered bytes are dropped unread.
          Response.new(status: 200, headers: {}, body: "", truncated: true)
        rescue Faraday::Error => e
          raise DownloadTooLarge if e.cause.is_a?(DownloadTooLarge)

          Response.new(status: 0, headers: {}, body: "", truncated: false)
        end

        # The Authorization header travels ONLY to the configured Infobip
        # account host. A media URL that redirected, or arrived pointing,
        # somewhere else must never carry this deployment's API key.
        def request_headers(uri)
          headers = { "Accept" => "image/*" }
          key = api_key
          headers["Authorization"] = "App #{key}" if key && account_host && uri.host.to_s.downcase == account_host
          headers
        end

        def api_key
          key = (@client || Decidim::Bih::Infobip::Client.new).api_key
          key.to_s.strip.empty? ? nil : key
        rescue StandardError
          nil
        end

        def header(response, name)
          headers = response.headers || {}
          headers.each { |key, value| return value if key.to_s.downcase == name }
          nil
        end

        def normalize_content_type(value)
          value.to_s.split(";").first.to_s.strip.downcase
        end

        def filename_for(content_type)
          "#{DEFAULT_BASENAME}#{EXTENSION_FOR.fetch(content_type, "")}"
        end

        def connection
          @connection ||= Faraday.new do |conn|
            conn.options.timeout = timeout
            conn.options.open_timeout = timeout
            conn.adapter Faraday.default_adapter
          end
        end

        def result(status, attachable: nil, content_type: nil, byte_size: nil)
          Result.new(status:, attachable:, content_type:, byte_size:)
        end

        # Logs the reason WITHOUT the URL or any byte of the body.
        def refuse(status, reason)
          Rails.logger.warn("[Infobip::ChatMediaFetch] refused (#{status}): #{reason}") if defined?(Rails) && Rails.respond_to?(:logger)
          result(status)
        end
      end
    end
  end
end

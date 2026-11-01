# frozen_string_literal: true

require "test_helper"
require "decidim/bih"
require "active_support/core_ext/object/blank"
require_relative "../../../../../app/services/decidim/bih/log_redactor"
require_relative "../../../../../app/services/decidim/bih/media/image_normalizer"
require_relative "../../../../../app/services/decidim/bih/infobip/error"
require_relative "../../../../../app/services/decidim/bih/infobip/client"
require_relative "../../../../../app/services/decidim/bih/infobip/chat_media_fetch"

module Decidim
  module Bih
    module Infobip
      # The chat photo fetcher must refuse with a REASON (so the adapter can
      # answer the citizen honestly), must never leak the media URL or a byte of
      # the photo into the log, and must never raise into the conversation.
      class ChatMediaFetchTest < Minitest::Test
        JPEG = File.binread(File.expand_path("../../../../fixtures/media/chat_photo.jpg", __dir__))
        MEDIA_URL = "https://api.infobip.com/whatsapp/1/senders/387/media/abc123?token=SECRET"

        class FakeLogger
          attr_reader :lines

          def initialize = @lines = []

          def warn(message) = @lines << message.to_s

          def error(message) = @lines << message.to_s

          def info(message) = @lines << message.to_s
        end

        # Records every call so "the flag off means zero HTTP calls" and "one
        # redirect at most" can be asserted against real call counts.
        class RecordingTransport
          attr_reader :calls

          def initialize(responses)
            @responses = Array(responses)
            @calls = []
          end

          def call(url:, headers:, timeout:, max_bytes:)
            @calls << { url:, headers:, timeout:, max_bytes: }
            @responses.fetch(@calls.length - 1) { @responses.last }
          end
        end

        def setup
          @original_env = ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
          ENV["INFOBIP_BASE_URL"] = "https://api.infobip.com"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
          ENV["INFOBIP_MEDIA_HOST_ALLOWLIST"] = nil
          ENV.delete("INFOBIP_MEDIA_HOST_ALLOWLIST")
          Config.reset!
        end

        def teardown
          @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Config.reset!
        end

        ENV_KEYS = %w(INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_MEDIA_HOST_ALLOWLIST).freeze

        def test_a_valid_jpeg_is_accepted_and_returned_as_an_attachable
          result = with_logger { fetch(response(200, "image/jpeg", JPEG)) }

          assert result.ok?
          assert_equal "image/jpeg", result.content_type
          assert_equal JPEG.bytesize, result.byte_size
          assert_equal "image/jpeg", result.attachable.fetch(:content_type)
          assert result.attachable.fetch(:io).respond_to?(:read)
          refute_empty result.attachable.fetch(:io).read
        end

        def test_an_oversized_body_is_refused_as_too_large
          oversize = "\xFF".b * (ChatMediaFetch::MAX_BYTES + 1)
          result = with_logger { fetch(response(200, "image/jpeg", oversize)) }

          assert_equal :too_large, result.status
          assert result.refused?
          assert_nil result.attachable
        end

        def test_a_transport_that_aborted_at_the_cap_is_refused_as_too_large
          truncated = ChatMediaFetch::Response.new(status: 200, headers: {}, body: "", truncated: true)
          result = with_logger { fetch(truncated) }

          assert_equal :too_large, result.status
        end

        def test_a_pdf_is_refused_as_an_invalid_type
          result = with_logger { fetch(response(200, "application/pdf", "%PDF-1.4 not an image")) }

          assert_equal :invalid_type, result.status
          assert_nil result.attachable
        end

        def test_bytes_that_are_not_a_readable_image_are_refused_as_an_invalid_type
          result = with_logger { fetch(response(200, "image/jpeg", "definitely not a jpeg")) }

          assert_equal :invalid_type, result.status
        end

        def test_a_404_from_the_provider_is_refused_as_a_fetch_failure
          result = with_logger { fetch(response(404, "text/plain", "not found")) }

          assert_equal :failed, result.status
        end

        def test_a_410_from_the_provider_is_refused_as_expired_media
          result = with_logger { fetch(response(410, "text/plain", "gone")) }

          assert_equal :expired, result.status
        end

        def test_a_server_error_is_refused_as_a_fetch_failure
          result = with_logger { fetch(response(500, "text/plain", "boom")) }

          assert_equal :failed, result.status
        end

        def test_a_blank_media_reference_is_not_an_error
          transport = RecordingTransport.new([])
          result = with_logger { ChatMediaFetch.new(transport:).call(nil) }

          assert_equal :none, result.status
          refute result.refused?
          assert_empty transport.calls
        end

        def test_one_redirect_is_followed_and_a_second_is_refused
          redirect = response(302, "text/plain", "", location: "https://api.infobip.com/media/final.jpg")
          transport = RecordingTransport.new([redirect, response(200, "image/jpeg", JPEG)])
          result = with_logger { ChatMediaFetch.new(transport:).call(MEDIA_URL) }

          assert result.ok?
          assert_equal 2, transport.calls.length

          loop_transport = RecordingTransport.new([redirect, redirect])
          looped = with_logger { ChatMediaFetch.new(transport: loop_transport).call(MEDIA_URL) }

          assert_equal :failed, looped.status
          assert_equal 2, loop_transport.calls.length
        end

        def test_a_redirect_off_the_allowlist_is_refused_without_a_second_request
          redirect = response(302, "text/plain", "", location: "http://169.254.169.254/latest/meta-data/")
          transport = RecordingTransport.new([redirect])
          result = with_logger { ChatMediaFetch.new(transport:).call(MEDIA_URL) }

          assert_equal :failed, result.status
          assert_equal 1, transport.calls.length
        end

        def test_a_url_off_the_allowlist_is_never_requested
          transport = RecordingTransport.new([response(200, "image/jpeg", JPEG)])
          %w(
            https://evil.example.com/photo.jpg
            https://evilinfobip.com/photo.jpg
            http://api.infobip.com/photo.jpg
            https://10.0.0.1/photo.jpg
            https://user:pass@api.infobip.com/photo.jpg
          ).each do |url|
            result = with_logger { ChatMediaFetch.new(transport:).call(url) }

            assert_equal :failed, result.status, url
          end

          assert_empty transport.calls
        end

        def test_the_api_key_travels_only_to_the_configured_account_host
          transport = RecordingTransport.new([response(200, "image/jpeg", JPEG)])
          with_logger { ChatMediaFetch.new(transport:).call(MEDIA_URL) }

          assert_equal "App test-api-key", transport.calls.first.fetch(:headers)["Authorization"]

          ENV["INFOBIP_MEDIA_HOST_ALLOWLIST"] = "media.example.org"
          other = RecordingTransport.new([response(200, "image/jpeg", JPEG)])
          with_logger { ChatMediaFetch.new(transport: other).call("https://media.example.org/photo.jpg") }

          refute other.calls.first.fetch(:headers).has_key?("Authorization")
        end

        def test_neither_the_url_nor_the_bytes_ever_reach_the_log
          logger = FakeLogger.new
          [response(410, "text/plain", "gone"), response(200, "application/pdf", "%PDF"),
           response(200, "image/jpeg", "\xFF".b * (ChatMediaFetch::MAX_BYTES + 1)),
           response(500, "text/plain", "boom")].each do |stub|
            with_logger(logger) { fetch(stub) }
          end

          refute_empty logger.lines
          logger.lines.each do |line|
            refute_includes line, "SECRET"
            refute_includes line, "api.infobip.com"
            refute_includes line, MEDIA_URL
            refute_includes line, "%PDF"
            refute_includes line, "test-api-key"
          end
        end

        def test_a_transport_explosion_never_raises_into_the_conversation
          exploding = Object.new
          exploding.define_singleton_method(:call) { |**| raise IOError, "connection reset to #{MEDIA_URL}" }
          logger = FakeLogger.new
          result = with_logger(logger) { ChatMediaFetch.new(transport: exploding).call(MEDIA_URL) }

          assert_equal :failed, result.status
          logger.lines.each { |line| refute_includes line, "api.infobip.com" }
        end

        private

        def fetch(stub)
          ChatMediaFetch.new(transport: RecordingTransport.new([stub])).call(MEDIA_URL)
        end

        def response(status, content_type, body, location: nil)
          headers = { "Content-Type" => content_type }
          headers["Location"] = location if location
          ChatMediaFetch::Response.new(status:, headers:, body:, truncated: false)
        end

        def with_logger(logger = FakeLogger.new)
          if Object.const_defined?(:Rails)
            return Rails.stub(:logger, logger) { yield } if Rails.respond_to?(:logger)

            Rails.define_singleton_method(:logger) { logger }
            return yield
          end

          rails = Module.new
          rails.define_singleton_method(:logger) { logger }
          Object.const_set(:Rails, rails)
          yield
        ensure
          if defined?(rails) && Object.const_defined?(:Rails) && Rails.equal?(rails)
            Object.send(:remove_const, :Rails)
          elsif Object.const_defined?(:Rails) && Rails.respond_to?(:logger) && Rails.logger.equal?(logger)
            Rails.singleton_class.send(:remove_method, :logger)
          end
        end
      end
    end
  end
end

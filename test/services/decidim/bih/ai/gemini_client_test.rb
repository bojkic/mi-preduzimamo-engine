# frozen_string_literal: true

require "test_helper"
require "json"
require "faraday"
require "active_support/core_ext/object/blank"
require "decidim/bih/config"
require "decidim/bih/instrumentation"
require_relative "../../../../../app/services/decidim/bih/log_redactor"
require_relative "../../../../../app/services/decidim/bih/ai/error"
require_relative "../../../../../app/services/decidim/bih/ai/gemini_client"

module Decidim
  module Bih
    module Ai
      # HTTP behaviour against Faraday's test adapter: no network, no key.
      class GeminiClientTest < Minitest::Test
        PATH = "/v1beta/models/gemini-test:generateContent"
        ENVELOPE = JSON.generate(
          "candidates" => [{ "content" => { "parts" => [{ "text" => JSON.generate("action" => "ask_information") }] } }]
        )

        def setup
          @now = 100.0
          @posts = []
          @stubs = Faraday::Adapter::Test::Stubs.new
        end

        def teardown
          @stubs.verify_stubbed_calls
        end

        def test_retries_once_on_a_5xx_or_429_when_asked_and_time_remains
          [503, 500, 429].each do |status|
            @posts.clear
            @stubs = Faraday::Adapter::Test::Stubs.new
            respond_with([status, 200])

            parsed = client.generate_content(contents: contents, timeout: 5.0, retry_once: true)

            assert_equal({ "action" => "ask_information" }, parsed, status)
            assert_equal 2, @posts.size, status
          end
        end

        def test_retries_once_on_a_transport_timeout_or_connection_failure
          [Faraday::TimeoutError, Faraday::ConnectionFailed].each do |error_class|
            @posts.clear
            @stubs = Faraday::Adapter::Test::Stubs.new
            respond_with([error_class, 200])

            parsed = client.generate_content(contents: contents, timeout: 5.0, retry_once: true)

            assert_equal({ "action" => "ask_information" }, parsed, error_class.name)
            assert_equal 2, @posts.size, error_class.name
          end
        end

        def test_does_not_retry_unless_asked
          respond_with([503, 200])

          assert_raises(Error) { client.generate_content(contents: contents, timeout: 5.0) }
          assert_equal 1, @posts.size

          @posts.clear
          @stubs = Faraday::Adapter::Test::Stubs.new
          respond_with([503, 200])
          assert_raises(Error) { client.generate_content(contents: contents, timeout: 5.0, retry_once: false) }
          assert_equal 1, @posts.size
        end

        def test_never_retries_a_client_error
          [400, 401, 403, 404].each do |status|
            @posts.clear
            @stubs = Faraday::Adapter::Test::Stubs.new
            respond_with([status, 200])

            error = assert_raises(Error, status) { client.generate_content(contents: contents, timeout: 5.0, retry_once: true) }

            assert_includes error.message, "HTTP #{status}"
            assert_equal 1, @posts.size, status
          end
        end

        def test_retries_exactly_once
          respond_with([503, 503, 200])

          assert_raises(Error) { client.generate_content(contents: contents, timeout: 5.0, retry_once: true) }
          assert_equal 2, @posts.size
        end

        def test_does_not_retry_when_less_than_one_and_a_half_seconds_remain
          respond_with([503, 200])
          assert_raises(Error) { client.generate_content(contents: contents, timeout: 1.4, retry_once: true) }
          assert_equal 1, @posts.size

          @posts.clear
          @stubs = Faraday::Adapter::Test::Stubs.new
          respond_with([503, 200], elapsed: 2.0)
          assert_raises(Error) { client.generate_content(contents: contents, timeout: 3.0, retry_once: true) }
          assert_equal 1, @posts.size
        end

        def test_retry_gets_only_the_remaining_time_measured_on_the_monotonic_clock
          respond_with([503, 200], elapsed: 1.0)

          client.generate_content(contents: contents, timeout: 5.0, retry_once: true)

          assert_in_delta 5.0, @posts.fetch(0).fetch(:timeout)
          assert_in_delta 4.0, @posts.fetch(1).fetch(:timeout)
        end

        def test_retry_without_a_call_timeout_measures_against_the_client_default
          respond_with([503, 200], elapsed: 1.0)

          client(timeout: 3.0).generate_content(contents: contents, retry_once: true)

          assert_equal 2, @posts.size
          assert_in_delta 3.0, @posts.fetch(0).fetch(:timeout)
          assert_in_delta 2.0, @posts.fetch(1).fetch(:timeout)
        end

        def test_never_retries_a_parse_error
          @stubs.post(PATH) do |env|
            record(env)
            [200, { "Content-Type" => "application/json" }, JSON.generate("candidates" => [{ "content" => { "parts" => [{ "text" => "not json" }] } }])]
          end

          assert_raises(Error) { client.generate_content(contents: contents, timeout: 5.0, retry_once: true) }
          assert_equal 1, @posts.size
        end

        def test_generation_limits_without_a_thinking_budget_omit_the_thinking_config
          respond_with([200])

          client.generate_content(contents: contents, response_schema: { type: "object" },
                                  generation_limits: { max_output_tokens: 512, candidate_count: 1 })

          config = @posts.fetch(0).fetch(:body).fetch("generationConfig")
          assert_equal({ "responseMimeType" => "application/json", "responseSchema" => { "type" => "object" },
                         "maxOutputTokens" => 512, "candidateCount" => 1 }, config)
        end

        def test_generation_limits_with_a_thinking_budget_keep_the_thinking_config
          respond_with([200])

          client.generate_content(contents: contents, generation_limits: { max_output_tokens: 256, candidate_count: 1, thinking_budget: 0 })

          config = @posts.fetch(0).fetch(:body).fetch("generationConfig")
          assert_equal({ "thinkingBudget" => 0 }, config.fetch("thinkingConfig"))
          assert_equal 256, config.fetch("maxOutputTokens")
        end

        def test_generation_limits_are_validated_before_any_request
          [
            { max_output_tokens: 512 },
            { max_output_tokens: 512, candidate_count: 2 },
            { max_output_tokens: 0, candidate_count: 1 },
            { max_output_tokens: 512, candidate_count: 1, temperature: 0 },
            { "max_output_tokens" => 512, "candidate_count" => 1 },
            []
          ].each do |limits|
            assert_raises(ArgumentError, limits.inspect) { client.generate_content(contents: contents, generation_limits: limits) }
          end
          assert_empty @posts
        end

        def test_unconfigured_client_raises_before_any_request
          assert_raises(Error) { client(api_key: nil).generate_content(contents: contents, retry_once: true) }
          assert_empty @posts
        end

        private

        def contents = [{ role: "user", parts: [{ text: "Pitanje" }] }]

        def client(api_key: "test-key", timeout: 20)
          connection = Faraday.new(url: "https://gemini.test") do |f|
            f.options.timeout = timeout
            f.options.open_timeout = timeout
            f.adapter :test, @stubs
          end
          GeminiClient.new(api_key:, model: "gemini-test", base_url: "https://gemini.test", timeout:,
                           connection:, clock: -> { @now })
        end

        # Each entry answers one POST in order: an HTTP status or an exception
        # class to raise. `elapsed` advances the injected clock per attempt.
        def respond_with(sequence, elapsed: 0.0)
          @stubs.post(PATH) do |env|
            record(env)
            @now += elapsed
            outcome = sequence.fetch(@posts.size - 1)
            raise outcome, "synthetic #{outcome.name}" if outcome.is_a?(Class)

            [outcome, { "Content-Type" => "application/json" }, outcome == 200 ? ENVELOPE : JSON.generate("error" => { "code" => outcome })]
          end
        end

        def record(env)
          @posts << { timeout: env.request.timeout, body: JSON.parse(env.body), key: env.request_headers["x-goog-api-key"] }
        end
      end
    end
  end
end

# frozen_string_literal: true

require "faraday"
require "active_support/core_ext/object/deep_dup"

module Decidim
  module Bih
    module Ai
      # Thin HTTP client for the Google Gemini generative-language API
      # (https://ai.google.dev). Shared Bosnian-market infrastructure: used by
      # the "Bice riseno" civic problem-report classifier. Reads credentials
      # from the environment so code is testable without them; when unconfigured,
      # callers fall back to a dev/heuristic path rather than erroring at build.
      #
      # Defaults (api_key/model/base_url) come from Decidim::Bih::Config.gemini,
      # which reads these env vars once and is the single boot-validated source:
      #   GEMINI_API_KEY   API key from Google AI Studio
      #   GEMINI_MODEL     model id
      #   GEMINI_BASE_URL  API host
      class GeminiClient
        DEFAULT_TIMEOUT = 20
        GENERATION_LIMIT_KEYS = [:max_output_tokens, :candidate_count, :thinking_budget].freeze
        REQUIRED_GENERATION_LIMIT_KEYS = [:max_output_tokens, :candidate_count].freeze
        # A second attempt needs enough of the caller's budget to be worth
        # making; below this the caller is better served by its own fallback.
        RETRY_MIN_REMAINING_SECONDS = 1.5
        RETRYABLE_ERRORS = [Faraday::TimeoutError, Faraday::ConnectionFailed].freeze

        MAX_INLINE_BYTES = 8 * 1024 * 1024
        attr_reader :base_url, :api_key, :model, :uncertainties, :last_usage

        # model/base_url default from the single boot-validated source
        # (Decidim::Bih::Config.gemini) so the values the live request uses can
        # never drift from what Config.validate! warns about. The api_key is read
        # the same way for symmetry; callers may still override any of them.
        # connection/clock exist for tests: a Faraday connection with the test
        # adapter and a monotonic clock that does not wait.
        # rubocop:disable Metrics/ParameterLists -- two test seams on an established constructor.
        def initialize(api_key: Decidim::Bih::Config.gemini[:api_key],
                       model: Decidim::Bih::Config.gemini[:model],
                       base_url: Decidim::Bih::Config.gemini[:base_url],
                       timeout: DEFAULT_TIMEOUT, connection: nil, clock: nil)
          @api_key = api_key
          @model = model.presence || Decidim::Bih::Config.gemini[:model]
          @base_url = base_url.presence || Decidim::Bih::Config.gemini[:base_url]
          @timeout = timeout
          @connection = connection
          @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        end
        # rubocop:enable Metrics/ParameterLists

        # True only when an API key is present. Callers use this to decide
        # between a real generation and a dev/heuristic fallback.
        def configured?
          api_key.present?
        end

        # Calls Gemini's generateContent with JSON-mode output. Returns the
        # parsed inner JSON the model emitted (as a Hash).
        # Raises Decidim::Bih::Ai::Error on transport, non-200 or parse failure.
        # With retry_once: true, one more attempt is made after a 429, a 5xx,
        # a timeout or a refused connection, provided at least
        # RETRY_MIN_REMAINING_SECONDS of the caller's timeout remain; a 4xx
        # other than 429 and a parse failure are never retried.
        # rubocop:disable Metrics/ParameterLists -- preserve the established callable API while adding opt-in controls.
        def generate_content(
          contents:, response_schema: nil, model: self.model, system_instruction: nil, timeout: nil, generation_limits: nil,
          retry_once: false
        )
          Decidim::Bih::Instrumentation.instrument(
            "gemini.generate_content",
            provider: "gemini",
            operation: "generate_content",
            model: model,
            configured: configured?
          ) do |event|
            raise Error, "Gemini client is not configured (set GEMINI_API_KEY)" unless configured?

            @last_usage = nil

            body = { contents: bounded_contents(contents), generationConfig: generation_config(response_schema, generation_limits) }
            instruction = system_instruction_content(system_instruction)
            body[:systemInstruction] = instruction if instruction
            response = post_with_retry(model_path(model), body, timeout:, retry_once:, event:)
            event[:http_status] = response.status
            payload = handle(response)
            @last_usage = payload["usageMetadata"] if payload.is_a?(Hash)
            extract(payload)
          end
        rescue Faraday::Error => e
          raise Error, "Gemini transport error: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end
        # rubocop:enable Metrics/ParameterLists

        private

        def bounded_contents(contents)
          @uncertainties = []
          contents.map.with_index do |content, index|
            copied = content.deep_dup
            parts_key = copied.key?(:parts) ? :parts : 'parts'
            copied[parts_key] = Array(copied[parts_key]).reject do |part|
              inline = part[:inlineData] || part['inlineData']
              next false unless inline
              bytes = (inline[:data] || inline['data']).to_s
              mime = inline[:mimeType] || inline['mimeType']
              dropped = bytes.bytesize > ((MAX_INLINE_BYTES + 2) / 3 * 4) || !%w(image/jpeg image/png image/webp application/pdf).include?(mime)
              @uncertainties << "inline_part_#{index}_unsupported_or_oversized" if dropped
              dropped
            end
            copied
          end
        end

        # Exactly one retry, only for a failure a second attempt can plausibly
        # fix, and only with the time the caller still has: the second request
        # gets the remainder of the caller's timeout measured on a monotonic
        # clock, so the pair can never outlast the budget the caller set.
        def post_with_retry(path, body, timeout:, retry_once:, event:)
          return post(path, body, timeout:) unless retry_once

          started = monotonic_now
          outcome = first_attempt(path, body, timeout:)
          return outcome if outcome.is_a?(Faraday::Response) && !retryable_status?(outcome.status)

          remaining = Float(timeout || @timeout) - (monotonic_now - started)
          if remaining < RETRY_MIN_REMAINING_SECONDS
            raise outcome if outcome.is_a?(Exception)

            return outcome
          end

          event[:retried] = true
          post(path, body, timeout: remaining)
        end

        # Returns the response, or the retryable exception the attempt raised.
        def first_attempt(path, body, timeout:)
          post(path, body, timeout:)
        rescue *RETRYABLE_ERRORS => e
          e
        end

        def retryable_status?(status)
          status == 429 || (500..599).cover?(status)
        end

        def monotonic_now
          Float(@clock.call)
        end

        # The Vertex AI (aiplatform.googleapis.com) endpoint uses a different path
        # than the AI Studio (generativelanguage) API; pick by the configured host.
        # Both authenticate with the x-goog-api-key header.
        def model_path(model)
          if base_url.to_s.include?("aiplatform")
            "/v1/publishers/google/models/#{model}:generateContent"
          else
            "/v1beta/models/#{model}:generateContent"
          end
        end

        def post(path, body, timeout: nil)
          connection.post(path) do |req|
            req.headers["Content-Type"] = "application/json"
            req.headers["Accept"] = "application/json"
            # Send the key via header, not the URL query string, to keep the
            # secret out of access logs / APM traces / error messages.
            req.headers["x-goog-api-key"] = api_key
            req.body = body.to_json
            apply_request_timeout(req, timeout)
          end
        end

        def system_instruction_content(value)
          return nil if value.nil?

          text = value.to_s
          return nil if text.strip.empty?

          { parts: [{ text: }] }
        end

        def apply_request_timeout(request, timeout)
          return if timeout.nil?

          seconds = Float(timeout)
          raise ArgumentError, "Gemini timeout must be finite and positive" unless seconds.finite? && seconds.positive?

          request.options.timeout = seconds
          request.options.open_timeout = seconds
        rescue TypeError
          raise ArgumentError, "Gemini timeout must be finite and positive"
        end

        def generation_config(response_schema, generation_limits)
          return legacy_generation_config(response_schema) if generation_limits.nil?

          validate_generation_limits!(generation_limits)
          config = {
            "responseMimeType" => "application/json",
            "responseSchema" => response_schema,
            "maxOutputTokens" => generation_limits.fetch(:max_output_tokens),
            "candidateCount" => generation_limits.fetch(:candidate_count)
          }
          # The thinking budget is opt-in: a caller that leaves it out keeps
          # the model's own default rather than forcing a value on it.
          config["thinkingConfig"] = { "thinkingBudget" => generation_limits.fetch(:thinking_budget) } if generation_limits.has_key?(:thinking_budget)
          config.compact
        end

        def legacy_generation_config(response_schema)
          config = { response_mime_type: "application/json" }
          config[:response_schema] = response_schema if response_schema
          config
        end

        def validate_generation_limits!(limits)
          raise ArgumentError, "Gemini generation limits must be a Hash" unless limits.is_a?(Hash)

          validate_generation_limit_keys!(limits)
          validate_integer_range!(limits.fetch(:max_output_tokens), 1..65_536, "max output tokens")
          validate_integer_value!(limits.fetch(:candidate_count), 1, "candidate count")
          validate_integer_value!(limits.fetch(:thinking_budget), 0, "thinking budget") if limits.has_key?(:thinking_budget)
        end

        def validate_generation_limit_keys!(limits)
          keys = limits.keys
          return if keys.all?(Symbol) && (keys - GENERATION_LIMIT_KEYS).empty? && (REQUIRED_GENERATION_LIMIT_KEYS - keys).empty?

          raise ArgumentError, "Gemini generation limits have unsupported keys"
        end

        def validate_integer_range!(value, range, name)
          return if value.is_a?(Integer) && range.cover?(value)

          raise ArgumentError, "Gemini #{name} must be an Integer in the approved range"
        end

        def validate_integer_value!(value, expected, name)
          return if value.is_a?(Integer) && value == expected

          raise ArgumentError, "Gemini #{name} must equal #{expected}"
        end

        def handle(response)
          return parse(response.body) if response.success?

          raise Error, "Gemini API error (HTTP #{response.status})"
        end

        # Digs the model's text part out of the envelope and parses it as JSON.
        def extract(payload)
          text = payload.dig("candidates", 0, "content", "parts", 0, "text")
          raise Error, "Gemini response missing content part" if text.blank?

          JSON.parse(strip_code_fence(text))
        rescue JSON::ParserError
          raise Error, "Gemini returned non-JSON content (finish=#{payload.dig("candidates", 0, "finishReason") || "unknown"})"
        end

        # The Vertex path sometimes wraps the JSON in a ```json ... ``` markdown
        # fence despite response_mime_type; strip it so JSON.parse still works.
        def strip_code_fence(text)
          stripped = text.strip
          return stripped unless stripped.start_with?("```")

          stripped.sub(/\A```[a-zA-Z]*[ \t]*\r?\n?/, "").sub(/\r?\n?```\s*\z/, "")
        end

        def parse(body)
          return body if body.is_a?(Hash)

          body.present? ? JSON.parse(body) : {}
        rescue JSON::ParserError => e
          raise Error, "Gemini returned a malformed envelope"
        end

        def connection
          @connection ||= Faraday.new(url: base_url) do |f|
            f.options.timeout = @timeout
            f.options.open_timeout = @timeout
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end

# frozen_string_literal: true

require "bigdecimal"
module Decidim
  module Bih
    module Ai
      # Reservations are conservative and never refunded after a request may
      # have reached Vertex. Retries each make a separate reservation.
      class CaseUsage
        Refused = Class.new(StandardError)
        PURPOSES = %w(primary check repair attachment).freeze
        # Official prices are separate from project/region access verification.
        VERIFIED_PRICES = {
          # Official price reviewed 2026-10-02. Reserve at the conservative
          # non-global post-intro upper bound, NOT an assertion of billed cost.
          'gemini-3.8-flash' => { verified: true, input: 1.65, output: 8.25, requires_access_receipt: true,
            source: 'https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing', reviewed_at: '2026-10-02' },
          'gemini-3.5-flash-lite' => { verified: true, input: 0.33, output: 2.75, requires_access_receipt: true,
            source: 'https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing', reviewed_at: '2026-10-02' }
        }.freeze
        attr_reader :reserved_usd_total
        def initialize(prices: VERIFIED_PRICES, cap: ENV.fetch('REPORT_CASE_DAILY_USD', '5'))
          @prices, @cap = prices, BigDecimal(cap.to_s)
          @reserved_usd_total = BigDecimal("0")
          raise Refused, 'invalid_budget' unless @cap.finite? && @cap.positive?
        end
        def reserve!(model:, purpose:, input_tokens:, output_tokens:)
          reserve_estimate!(model:, purpose:, input_tokens:, output_tokens:, require_access_receipt: true)
        end

        # The sole access-receipt bypass sends a fixed minimal access question,
        # not an arbitrary case prompt. Published verified pricing and the same
        # atomic daily budget still apply; uncertain outcomes are fully charged.
        def probe(client:, model:)
          contents = [{ role: 'user', parts: [{ text: 'Return {"ok":true}.' }] }]
          options = { response_schema: { type: 'object', properties: { ok: { type: 'boolean' } }, required: ['ok'] },
                      generation_limits: { max_output_tokens: 256, candidate_count: 1, thinking_budget: 0 }, timeout: 15 }
          reserve_estimate!(model:, purpose: 'access_probe', input_tokens: contents.to_json.bytesize + options.to_json.bytesize,
                            output_tokens: 256, require_access_receipt: false)
          client.generate_content(contents:, model:, retry_once: false, **options)
        end

        private

        def reserve_estimate!(model:, purpose:, input_tokens:, output_tokens:, require_access_receipt:)
          permitted = require_access_receipt ? PURPOSES.include?(purpose.to_s) : purpose == 'access_probe' && output_tokens == 256 && input_tokens <= 4096
          raise Refused, 'unknown_call_type' unless permitted
          price = @prices[model.to_s]
          raise Refused, 'unverified_or_unpriced_model' unless price && price[:verified] == true
          raise Refused, 'model_access_unverified' if require_access_receipt && price[:requires_access_receipt] && !Config.report_case_model_access_verified?(model)
          raise Refused, 'invalid_token_bound' unless [input_tokens, output_tokens].all? { |n| n.is_a?(Integer) && n.positive? }
          estimate = (BigDecimal(price.fetch(:input).to_s) * input_tokens + BigDecimal(price.fetch(:output).to_s) * output_tokens) / 1_000_000
          raise Refused, 'invalid_price' unless estimate.finite? && estimate.positive?
          row = CaseUsageDay.create_or_find_by!(day: Time.current.utc.to_date)
          row.with_lock do
            raise Refused, 'daily_budget_exceeded' if row.reserved_usd + estimate > @cap
            row.update!(reserved_usd: row.reserved_usd + estimate)
          end
          @reserved_usd_total += estimate
          estimate
        end
        public

        def call(client:, model:, purpose:, contents:, **options)
          # UTF-8 bytes are a conservative token upper bound. Binary parts are
          # charged at their encoded-byte bound, including PDF and image calls.
          day = Time.current.utc.to_date
          estimate = reserve!(model:, purpose:, input_tokens: contents.to_json.bytesize + options.to_json.bytesize,
                              output_tokens: options.fetch(:generation_limits).fetch(:max_output_tokens))
          client.generate_content(contents:, model:, retry_once: false, **options)
        ensure
          settle!(estimate, model:, day:, usage: client.respond_to?(:last_usage) ? client.last_usage : nil) if estimate
        end

        # Owner question 2026-10-06: the cap was consumed ~6x faster than real
        # spend. When the provider reports its token counts, release the part of
        # the reservation that was not used (thinking tokens are billed as output).
        # Without a report (timeout, transport error) the full reservation stays.
        def settle!(estimate, model:, day:, usage:)
          return unless usage.is_a?(Hash)

          price = @prices.fetch(model.to_s)
          output = usage["candidatesTokenCount"].to_i + usage["thoughtsTokenCount"].to_i
          actual = (BigDecimal(price.fetch(:input).to_s) * usage["promptTokenCount"].to_i + BigDecimal(price.fetch(:output).to_s) * output) / 1_000_000
          refund = estimate - actual
          return unless refund.positive?

          row = CaseUsageDay.find_by(day:)
          row&.with_lock { row.update!(reserved_usd: [row.reserved_usd - refund, 0].max) }
          @reserved_usd_total -= refund
        rescue StandardError => e
          Rails.logger.warn("[CaseUsage] settle skipped error=#{e.class}")
        end
      end
    end
  end
end

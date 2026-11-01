# frozen_string_literal: true

require "bigdecimal"
require "digest"

module Decidim
  module Bih
    module Odoo
      # Mirrors "total donations raised" out of the foundation's Odoo webshop
      # into the Decidim platform. Donations are website `sale.order`s whose
      # lines reference the donation/membership `product.template`s; a confirmed
      # donation is one in an accepted state ("sale"/"done"). We sum the line
      # amounts (not order totals) so a confirmed order that mixes a donation
      # with a non-donation product still contributes only its donation lines.
      #
      # GENERAL FUND: donations are not earmarked per Decidim project, so this is
      # a single "total raised" figure (amount + distinct-order count, optional
      # date window), NOT a per-project progress bar.
      #
      # GRACEFUL DEGRADATION: #call NEVER raises. An unconfigured client or any
      # Odoo transport/fault error logs and yields a zeroed Result, mirroring how
      # The concierge degrade — a flaky
      # Odoo can never break a page render or the bot.
      #
      # NON-BLOCKING READS: web requests read #cached (Rails.cache); the live
      # Odoo query runs only in #refresh! (the background job). On a cold cache
      # #cached enqueues a refresh and returns a cheap zeroed value, so a render
      # never blocks on Odoo.
      class DonationTotals
        # Every installation supplies its own reviewed product.template ids.
        # No configured products means no query and no refresh enqueue.
        DEFAULT_PRODUCT_IDS = [].freeze

        # sale.order states that count as a confirmed (collected) donation.
        # `draft` (abandoned cart) and `sent` (unconfirmed quote) are excluded.
        DEFAULT_CONFIRMED_STATES = %w(sale done).freeze

        # Donations are charged in Bosnian convertible marks.
        DEFAULT_CURRENCY = "BAM"

        # How long a computed total stays fresh in Rails.cache. Must comfortably
        # outlast the configured refresh cadence (for example, hourly)
        # so the key never expires in the gap between refreshes; 90 minutes gives a
        # ~30-minute safety margin on top of an hourly refresh.
        CACHE_TTL = 90.minutes
        REFRESH_LOCK_TTL = 2.minutes

        # We aggregate over order LINES so mixed orders stay correct.
        LINE_MODEL = "sale.order.line"

        # Tax-inclusive line total. Donations are untaxed so it equals
        # price_subtotal, but it is the canonical "what the donor paid" field;
        # we fall back to price_subtotal if an instance lacks it.
        AMOUNT_FIELD = "price_total"
        FALLBACK_AMOUNT_FIELD = "price_subtotal"

        # The immutable result handed to callers. +as_of+ is nil for a zeroed
        # (unconfigured/errored/cold-cache) result and a Time for a real query.
        # :count is a data field (donation order count), intentionally shadowing
        # Struct#count — callers want the figure, never the member arity.
        Result = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) do # rubocop:disable Lint/StructNewOverride
          # A cheap zeroed value used when Odoo is unavailable or the cache is
          # cold, so callers always get a renderable shape.
          def self.zero(currency: DEFAULT_CURRENCY)
            new(total: BigDecimal("0"), count: 0, currency: currency, as_of: nil)
          end
        end

        def initialize(client: Decidim::Bih::Odoo::Client.new, # rubocop:disable Metrics/ParameterLists
                       product_ids: DEFAULT_PRODUCT_IDS,
                       confirmed_states: DEFAULT_CONFIRMED_STATES,
                       date_from: nil,
                       currency: DEFAULT_CURRENCY,
                       cache_namespace: "global",
                       extra_domain: [])
          @client = client
          @product_ids = Array(product_ids)
          @confirmed_states = Array(confirmed_states)
          @date_from = date_from
          @currency = currency
          @cache_namespace = cache_namespace
          @extra_domain = Array(extra_domain)
        end

        # Computes the live total by querying Odoo. NEVER raises: an unconfigured
        # client or any Odoo/unexpected error logs and returns a zeroed Result.
        def call(raise_errors: false)
          return Result.zero(currency: currency) if product_ids.empty?
          return Result.zero(currency: currency) unless client.configured?

          lines = client.read(LINE_MODEL, domain, fields, limit: false)
          summarize(lines)
        rescue Decidim::Bih::Odoo::Error => e
          raise if raise_errors

          Rails.logger.warn("[DonationTotals] Odoo query failed (#{e.message}); returning zero")
          Result.zero(currency: currency)
        rescue StandardError => e
          raise if raise_errors

          Rails.logger.warn("[DonationTotals] unexpected error (#{e.class}: #{e.message}); returning zero")
          Result.zero(currency: currency)
        end

        # Recomputes via Odoo and writes the result to Rails.cache. Returns it.
        # This is the only path that talks to Odoo synchronously; call it from
        # the background refresh job, never from a web request.
        #
        # LAST-KNOWN-GOOD: only a SUCCESSFUL fetch updates the cache. An errored /
        # unconfigured fetch yields a zeroed Result (as_of: nil); writing that would
        # clobber the last-known-good total with 0 KM until the TTL expires (so
        # /donacije and the concierge would show 0). On such a fetch we keep the
        # previously cached value untouched and just return the zeroed Result. A
        # genuinely-empty successful query (total 0, as_of set) still updates.
        def refresh!(raise_errors: false)
          result = call(raise_errors:)
          Rails.cache.write(cache_key, result, expires_in: CACHE_TTL) if result.as_of.present?
          Rails.cache.delete(refresh_lock_key)
          result
        end

        # Non-blocking read for page renders / the bot: returns the cached Result
        # when present; otherwise enqueues a background refresh and returns a
        # cheap zeroed (stale) Result so the request never blocks on Odoo.
        def cached
          return Result.zero(currency: currency) if product_ids.empty?

          cached_result = Rails.cache.read(cache_key)
          return cached_result if cached_result

          enqueue_refresh_once
          Result.zero(currency: currency)
        end

        # Cache key namespaced by caller (organization) AND the full config, so a
        # different product set / state set / date window can't read a stale key.
        def cache_key
          [
            "decidim_bih", "odoo", "donation_totals",
            cache_namespace,
            product_ids.sort.join("-"),
            confirmed_states.sort.join("-"),
            date_from.presence&.to_s,
            domain_cache_digest
          ].compact.join("/")
        end

        def refresh_lock_key
          "#{cache_key}/refresh-lock"
        end

        private

        attr_reader :client, :product_ids, :confirmed_states, :date_from, :currency, :cache_namespace, :extra_domain

        def enqueue_refresh_once
          locked = Rails.cache.write(refresh_lock_key, true, expires_in: REFRESH_LOCK_TTL, unless_exist: true)
          enqueue_refresh if locked
        rescue StandardError => e
          Rails.logger.warn("[DonationTotals] could not acquire refresh lock (#{e.class}: #{e.message})")
          enqueue_refresh
        end

        def enqueue_refresh
          Decidim::Bih::Odoo::RefreshDonationTotalsJob.perform_later(
            product_ids: product_ids,
            confirmed_states: confirmed_states,
            date_from: date_from.presence&.to_s,
            currency: currency,
            cache_namespace: cache_namespace,
            extra_domain: extra_domain
          )
        rescue StandardError => e
          Rails.logger.warn("[DonationTotals] could not enqueue refresh (#{e.class}: #{e.message})")
        end

        # Filters by LINE (not order) so a confirmed order that mixes a donation
        # with another product contributes only its donation lines.
        def domain
          conditions = [
            ["order_id.state", "in", confirmed_states],
            ["product_id.product_tmpl_id", "in", product_ids]
          ]
          conditions << ["order_id.date_order", ">=", date_from.to_s] if date_from.present?
          conditions + extra_domain
        end

        def domain_cache_digest
          return if extra_domain.blank?

          Digest::SHA256.hexdigest(extra_domain.to_json)[0, 16]
        end

        def fields
          [AMOUNT_FIELD, "order_id"]
        end

        def summarize(lines)
          rows = Array(lines)
          total = rows.sum(BigDecimal("0")) { |row| amount_of(row) }
          count = rows.filter_map { |row| order_id_of(row) }.uniq.size
          Result.new(total: total, count: count, currency: currency, as_of: Time.current)
        end

        def amount_of(row)
          value = row[AMOUNT_FIELD]
          value = row[FALLBACK_AMOUNT_FIELD] if value.nil?
          BigDecimal(value.to_s)
        rescue ArgumentError
          BigDecimal("0")
        end

        # Odoo many2one fields read back as [id, "Display Name"]; take the id so
        # the distinct-order count is correct.
        def order_id_of(row)
          reference = row["order_id"]
          reference.is_a?(Array) ? reference.first : reference
        end
      end
    end
  end
end

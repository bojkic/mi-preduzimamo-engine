# frozen_string_literal: true

require "redis"
require "decidim/bih/safe_error_metadata"
require "decidim/bih/redis_endpoint"

module Decidim
  module Bih
    # Durable, REDIS-backed observability for external integrations. It turns the
    # transient Decidim::Bih::Instrumentation event stream (gemini.*, infobip.*,
    # odoo.*, sistem48.*, report_processing) into a small persisted per-provider
    # health record the admin "integrations health" page can read.
    #
    # PRIVACY: the instrumentation payloads are already metadata-only (scrubbed
    # by Instrumentation before they reach any subscriber). This service is the
    # last line of defence: it stores ONLY a fixed, allow-listed set of scalar
    # fields (timestamps, an http status, a scrubbed error class/code, success /
    # failure tallies). It NEVER serializes the whole payload, so a raw message
    # that ever slipped into a payload could not be persisted here.
    #
    # NO DATABASE: there is intentionally no migration. State lives in Redis
    # (the same instance Sidekiq/rack-attack use, read via REDIS_URL the way
    # Viber::OtpStore does) and is purely advisory — losing it on a Redis flush
    # just resets the page to "unknown" until the next call.
    #
    # The store is injectable so the unit test can pass an in-memory store and
    # never depend on Redis being up; production defaults to RedisStore.
    class IntegrationHealth
      KEY_PREFIX = "bih:integration_health"

      # The Decidim::Bih::Instrumentation topics this subscriber records. Each is
      # the full AS::Notifications name (the "decidim_bih." prefix + the suffix
      # the client passes). Listing them explicitly (rather than a broad
      # "decidim_bih.*" regex) keeps unrelated engine notifications — goodwill
      # awards, test events — out of the health record.
      TOPICS = %w(
        decidim_bih.gemini.generate_content
        decidim_bih.odoo.rpc
        decidim_bih.infobip.request
        decidim_bih.sistem48.forward
        decidim_bih.report_processing
      ).freeze

      # A success/failure within this window counts as current. Older state is
      # explicitly stale: high-impact fan-out must never treat an old success
      # or failure as proof that the provider is ready now.
      RECENT_WINDOW = 15 * 60
      STORE_TTL = 30.days.to_i

      # Per-provider rolling tally cap. We only need "the last N calls" texture
      # for the admin page, not a full time series — keep the stored counters
      # bounded and cheap.
      TALLY_CAP = 100

      class << self
        # Process-wide singleton used by the AS::Notifications subscriber and the
        # admin controller. Lazily built so merely loading the engine never opens
        # a Redis socket.
        def instance
          @instance ||= new
        end

        # Test seam: swap in an instance backed by an injected store (e.g. a
        # MemoryStore) so integration tests of the controller never need Redis.
        attr_writer :instance

        # Test seam: drop the memoized singleton (and any injected store).
        def reset!
          @instance = nil
        end

        # Subscribes the durable recorder to every integration topic. IDEMPOTENT:
        # a process-wide guard means a second call (a stray re-install, or this
        # running alongside the engine's after_initialize) never double-subscribes
        # — so an event is recorded exactly once. Each subscriber block is fully
        # rescued inside #record, so a recording failure never breaks the
        # instrumented call.
        #
        # Called from the engine's after_initialize (runs ONCE after boot, not on
        # code reload), mirroring how goodwill EventSubscriptions is installed.
        def install!
          return if @installed

          @subscribers = TOPICS.map do |topic|
            ActiveSupport::Notifications.subscribe(topic) do |name, _start, _finish, _id, payload|
              instance.record(name, payload)
            end
          end
          @installed = true
        end

        # Test seam: tear the subscriptions down and clear the guard so install!
        # can be exercised cleanly.
        def uninstall!
          Array(@subscribers).each { |s| ActiveSupport::Notifications.unsubscribe(s) }
          @subscribers = nil
          @installed = false
        end
      end

      def initialize(store: nil)
        @store = store
      end

      # Records one instrumentation event. Fully rescued: a health-recording
      # failure (e.g. Redis down) must NEVER break the instrumented call, so this
      # swallows everything and logs at warn level.
      #
      # +name+    — the full AS::Notifications topic, e.g. "decidim_bih.odoo.rpc".
      # +payload+ — the (already scrubbed) instrumentation payload.
      def record(name, payload)
        provider = provider_for(name, payload)
        return if provider.blank?

        org = organization_bucket(payload)

        if truthy?(payload[:success])
          store.record_success(provider:, organization: org, at: Time.now.to_i)
        else
          store.record_failure(
            provider:,
            organization: org,
            at: Time.now.to_i,
            error_code: scrubbed_error_code(payload),
            error_class: scrubbed_error_class(payload)
          )
        end
      rescue StandardError => e
        Rails.logger.warn("[Decidim::Bih::IntegrationHealth] record failed: #{e.class}")
        nil
      end

      # Read API for the controller. Returns a symbol-keyed Hash with a stable
      # shape regardless of whether the provider has ever been seen:
      # A provider blocks a high-impact send only when there is EVIDENCE that it
      # is failing. `:stale` and `:unknown` are the absence of evidence, not
      # evidence of absence: this tally is only ever written by real outbound
      # phone traffic, so on a platform where that traffic is intermittent,
      # "no observation in the last 15 minutes" is the ordinary state. Requiring
      # `:ok` therefore hid the Viber controls almost all the time, which is not
      # a safety property — it is a broken one, and operators read it as a
      # missing feature.
      #
      # Nor was `:ok` ever proof of deliverability: a sender sat DISCONNECTED at
      # the provider for two days here while this tally stayed green. What does
      # protect a send is downstream and unchanged — the dispatch confirmation,
      # per-recipient eligibility at delivery, a recorded failure status and the
      # retry path. A provider that dies after this check cannot lose a message
      # silently.
      def send_blocked?(provider:, organization_id: nil)
        state(provider:, organization_id:).to_h[:status] == :failing
      end

      #   { last_success_at:, last_error_at:, last_error_code:, last_error_class:,
      #     success_count:, failure_count:, status: }
      # status is one of :ok, :failing, :stale, :unknown.
      def state(provider:, organization_id: nil)
        raw = store.read(provider: provider.to_s, organization: organization_key(organization_id)) || {}

        last_success_at = to_time(raw[:last_success_at])
        last_error_at = to_time(raw[:last_error_at])
        success_count = raw[:success_count].to_i
        failure_count = raw[:failure_count].to_i

        latest_at = [last_success_at, last_error_at].compact.max
        {
          last_success_at:,
          last_error_at:,
          last_error_code: raw[:last_error_code],
          last_error_class: raw[:last_error_class],
          success_count:,
          failure_count:,
          status: summarize(last_success_at, last_error_at, success_count + failure_count),
          observed_at: latest_at
        }
      rescue StandardError => e
        Rails.logger.warn("[Decidim::Bih::IntegrationHealth] state read failed: #{e.class}")
        empty_state
      end

      private

      attr_reader :store

      def store
        @store ||= RedisStore.new
      end

      # Provider bucket: prefer the explicit :provider key the clients set; fall
      # back to the first segment of the topic suffix (drops the "decidim_bih."
      # prefix), so report_processing (which sets no :provider) still buckets.
      def provider_for(name, payload)
        return payload[:provider].to_s if payload[:provider].present?

        suffix = name.to_s.sub(/\A#{Regexp.escape(Decidim::Bih::Instrumentation::PREFIX)}\./, "")
        suffix.split(".").first
      end

      # Org-or-global bucket. Most provider clients are organization-agnostic
      # (one set of credentials per deployment) and emit no organization_id;
      # those record under the "global" bucket. report_processing carries one.
      def organization_bucket(payload)
        organization_key(payload[:organization_id])
      end

      def organization_key(value)
        value.present? ? value.to_s : "global"
      end

      def scrubbed_error_code(payload)
        code = payload[:http_status] || payload[:error_code]
        return if code.blank?

        Decidim::Bih::SafeErrorMetadata.sanitize_text(code.to_s, max: 32)
      end

      def scrubbed_error_class(payload)
        klass = payload[:error_class]
        return if klass.blank?

        Decidim::Bih::SafeErrorMetadata.sanitize_text(klass.to_s, max: 120)
      end

      def truthy?(value)
        value == true || value.to_s == "true"
      end

      def to_time(value)
        return if value.blank?

        Time.zone.at(value.to_i)
      end

      # Status summary the view colours on:
      #   :failing — the most recent event in the window was a failure
      #   :ok      — there is a success and no more-recent failure
      #   :stale   — the latest observation is older than RECENT_WINDOW
      #   :unknown — nothing recorded yet
      def summarize(last_success_at, last_error_at, total)
        return :unknown if total.zero?

        latest_at = [last_success_at, last_error_at].compact.max
        return :stale if latest_at.nil? || latest_at < RECENT_WINDOW.seconds.ago

        if last_error_at && (last_success_at.nil? || last_error_at >= last_success_at)
          :failing
        else
          :ok
        end
      end

      def empty_state
        {
          last_success_at: nil,
          last_error_at: nil,
          last_error_code: nil,
          last_error_class: nil,
          success_count: 0,
          failure_count: 0,
          status: :unknown,
          observed_at: nil
        }
      end

      # In-memory store for tests (and any non-Redis context). Same contract as
      # RedisStore but backed by a plain Hash, so the IntegrationHealth unit test
      # never opens a socket.
      class MemoryStore
        def initialize
          @data = Hash.new { |h, k| h[k] = {} }
        end

        def record_success(provider:, organization:, at:)
          bucket = @data[key(provider, organization)]
          bucket[:last_success_at] = at
          bucket[:success_count] = bump(bucket[:success_count])
        end

        def record_failure(provider:, organization:, at:, error_code:, error_class:)
          bucket = @data[key(provider, organization)]
          bucket[:last_error_at] = at
          bucket[:last_error_code] = error_code
          bucket[:last_error_class] = error_class
          bucket[:failure_count] = bump(bucket[:failure_count])
        end

        def read(provider:, organization:)
          @data[key(provider, organization)].dup
        end

        # Test helper: the full stored state (used to assert no raw data leaks).
        def dump
          @data
        end

        private

        def bump(value)
          [value.to_i + 1, TALLY_CAP].min
        end

        def key(provider, organization)
          "#{provider}|#{organization}"
        end
      end

      # Redis-backed store. Each (provider, org) bucket is a single Redis HASH;
      # we only ever HSET a fixed allow-list of scalar fields and HINCRBY the
      # bounded counters. The connection is lazy + mirrors REDIS_URL the way
      # Viber::OtpStore does. Counters are capped so they stay small.
      class RedisStore
        def initialize(redis: nil)
          @redis = redis
        end

        def record_success(provider:, organization:, at:)
          redis_key = key(provider, organization)
          redis.hset(redis_key, "last_success_at", at)
          bump(redis_key, "success_count")
          redis.expire(redis_key, STORE_TTL)
        end

        def record_failure(provider:, organization:, at:, error_code:, error_class:)
          redis_key = key(provider, organization)
          fields = { "last_error_at" => at }
          fields["last_error_code"] = error_code if error_code
          fields["last_error_class"] = error_class if error_class
          redis.mapped_hmset(redis_key, fields)
          bump(redis_key, "failure_count")
          redis.expire(redis_key, STORE_TTL)
        end

        def read(provider:, organization:)
          raw = redis.hgetall(key(provider, organization))
          return {} if raw.blank?

          raw.transform_keys(&:to_sym)
        end

        private

        def redis
          @redis ||= Redis.new(url: Decidim::Bih::RedisEndpoint.url)
        end

        # Bounded increment: reset to 1 once the counter would exceed the cap so
        # the stored value never grows without limit.
        def bump(redis_key, field)
          count = redis.hincrby(redis_key, field, 1)
          redis.hset(redis_key, field, 1) if count > TALLY_CAP
        end

        def key(provider, organization)
          "#{KEY_PREFIX}:#{organization}:#{provider}"
        end
      end
    end
  end
end

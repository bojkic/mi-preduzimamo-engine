# frozen_string_literal: true

require "global_id"
require "active_job"
require "active_job/arguments"
require "active_support/isolated_execution_state"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/string/inflections"
require "json"
require "redis"
require "decidim/bih/redis_endpoint"

module Decidim
  module Bih
    # Captures the small set of external side effects that may be produced while
    # a durable inbound receipt owns the current execution. The receipt persists
    # these descriptors in an authenticated encrypted envelope before its civic
    # database transaction commits, then replays them with a durable cursor.
    #
    # Callers do not need to know whether capture is active. Outside inbound
    # processing every operation keeps its normal immediate behavior.
    module DurableEffects
      Capture = Struct.new(:result, :effects, keyword_init: true)
      EnqueueError = Class.new(StandardError)

      CONTEXT_KEY = :decidim_bih_durable_effects_context
      MAX_EFFECTS = 128
      MAX_PLAINTEXT_BYTES = 512 * 1024
      MAX_KEY_BYTES = 512
      MAX_REDIS_KEYS = 8
      TOMBSTONE_EFFECT = { "type" => "tombstone" }.freeze

      ACTIVE_JOB_ALLOWLIST = %w(
        Decidim::Bih::Goodwill::GoodwillAwardJob
        Decidim::Bih::Infobip::SendChatTextJob
        Decidim::Bih::Infobip::SendPhoneMessageJob
        Decidim::Bih::Infobip::SendViberImageJob
        Decidim::Bih::Infobip::SendViberTextJob
        Decidim::Bih::KomsilukPostNotificationJob
        Decidim::Bih::ReportProcessingJob
        Decidim::Bih::ReportStaffAlertJob
      ).freeze
      CACHE_WRITE_OPTIONS = %w(expires_in unless_exist race_condition_ttl).freeze
      REDIS_SET_OPTIONS = %w(ex px nx xx).freeze
      REDIS_SCRIPT_REGISTRY = {
        "viber_otp_put_v1" => {
          script: -> { Decidim::Bih::Viber::OtpStore::PUT_SCRIPT },
          ttl_argv_index: 1,
          ttl_unit: :seconds
        }.freeze
      }.freeze
      EFFECT_TYPES = %w(active_job cache_write redis_delete redis_eval redis_set tombstone).freeze
      EFFECT_VALIDATORS = {
        "active_job" => :validate_active_job_effect!,
        "cache_write" => :validate_keyed_effect!,
        "redis_delete" => :validate_redis_delete_effect!,
        "redis_eval" => :validate_redis_eval_effect!,
        "redis_set" => :validate_keyed_effect!,
        "tombstone" => :validate_tombstone_effect!
      }.freeze

      class Context
        attr_reader :effects

        def initialize
          @effects = []
        end

        def append(effect)
          candidate = effects + [effect]
          raise ArgumentError, "Inbound effect count exceeds #{MAX_EFFECTS}" if candidate.size > MAX_EFFECTS
          raise ArgumentError, "Inbound effect payload exceeds #{MAX_PLAINTEXT_BYTES} bytes" if
            JSON.generate(candidate).bytesize > MAX_PLAINTEXT_BYTES

          effects << effect
          :deferred
        end
      end

      module_function

      def active?
        !current_context.nil?
      end

      # Internal receipt boundary, public so host applications can exercise the
      # contract without reaching into InboundDelivery implementation details.
      def capture
        raise ArgumentError, "A durable effect context is already active" if active?

        context = Context.new
        ActiveSupport::IsolatedExecutionState[CONTEXT_KEY] = context
        installed = true
        Capture.new(result: yield, effects: context.effects.map(&:dup))
      ensure
        ActiveSupport::IsolatedExecutionState.delete(CONTEXT_KEY) if installed
      end

      def enqueue(job, *arguments, effect_expires_at: nil, **keyword_arguments)
        return perform_later(job, arguments, keyword_arguments) unless active?

        job_name = job.name.to_s
        raise ArgumentError, "ActiveJob class is not allowed for durable inbound effects" unless
          ACTIVE_JOB_ALLOWLIST.include?(job_name)

        effect = {
          "type" => "active_job",
          "job_class" => job_name,
          "arguments" => serialize_job_arguments(job, arguments, keyword_arguments)
        }
        attach_absolute_deadline!(effect, effect_expires_at) unless effect_expires_at.nil?
        append(expired?(effect) ? tombstone : effect)
      end

      def cache_write(key, value, cache: Rails.cache, **options)
        return cache.write(key, value, **options) unless active?

        effect = {
          "type" => "cache_write",
          "key" => bounded_key(key),
          "value" => serialize_value(value),
          "options" => serialize_options(options, allowlist: CACHE_WRITE_OPTIONS)
        }
        attach_deadline!(effect, options[:expires_in], unit: :seconds) if options.has_key?(:expires_in)
        append(effect)
      end

      def redis_set(redis:, key:, value:, **options)
        return redis.set(key, value, **options) unless active?

        effect = {
          "type" => "redis_set",
          "key" => bounded_key(key),
          "value" => serialize_value(value),
          "options" => serialize_options(options, allowlist: REDIS_SET_OPTIONS)
        }
        attach_redis_set_deadline!(effect, options)
        append(effect)
      end

      def redis_delete(*keys, redis:)
        return redis.del(*keys) unless active?

        normalized_keys = Array(keys).flatten.map { |key| bounded_key(key) }
        raise ArgumentError, "A Redis delete requires at least one key" if normalized_keys.empty?
        raise ArgumentError, "Redis delete exceeds #{MAX_REDIS_KEYS} keys" if normalized_keys.size > MAX_REDIS_KEYS

        append("type" => "redis_delete", "keys" => normalized_keys)
      end

      def redis_eval(redis:, script_id:, keys:, argv: [])
        script_id = script_id.to_s
        raise ArgumentError, "Redis script is not allowed for durable inbound effects" unless
          REDIS_SCRIPT_REGISTRY.has_key?(script_id)

        normalized_keys = Array(keys).map { |key| bounded_key(key) }
        raise ArgumentError, "A Redis script requires at least one key" if normalized_keys.empty?
        raise ArgumentError, "Redis script exceeds #{MAX_REDIS_KEYS} keys" if normalized_keys.size > MAX_REDIS_KEYS

        normalized_argv = Array(argv)
        effect = {
          "type" => "redis_eval",
          "script_id" => script_id,
          "keys" => normalized_keys,
          "argv" => serialize_value(normalized_argv)
        }
        unless active?
          registry = REDIS_SCRIPT_REGISTRY.fetch(script_id)
          return redis.eval(registry.fetch(:script).call, keys: normalized_keys, argv: normalized_argv)
        end

        attach_script_deadline!(effect, normalized_argv, REDIS_SCRIPT_REGISTRY.fetch(script_id))
        append(effect)
      end

      def dispatch!(effect, cache: nil, redis: nil)
        validate_effect!(effect)
        return :tombstone if tombstone?(effect)
        return :expired if expired?(effect)

        case effect.fetch("type")
        when "active_job"
          dispatch_job(effect)
        when "cache_write"
          dispatch_cache_write(effect, cache:)
        when "redis_set"
          dispatch_redis_set(effect, redis:)
        when "redis_delete"
          dispatch_redis_delete(effect, redis:)
        when "redis_eval"
          dispatch_redis_eval(effect, redis:)
        end
      end

      # A tombstone deliberately retains only the array slot needed for the
      # durable cursor/count invariant. It carries no completed or expired
      # effect payload and is always safe to dispatch as a no-op.
      def tombstone
        TOMBSTONE_EFFECT.dup
      end

      def tombstone?(effect)
        effect.is_a?(Hash) && effect["type"] == "tombstone"
      end

      def expired?(effect, now: Time.current)
        deadline = deadline_at(effect)
        return false if deadline.nil?

        deadline <= now.to_time
      end

      def deadline_at(effect)
        deadline = effect["deadline_at_ms"]
        return if deadline.nil?

        Time.at(Integer(deadline) / 1000.0).utc
      rescue ArgumentError, TypeError, NoMethodError
        raise ArgumentError, "Durable effect deadline is invalid"
      end

      def validate_effects!(effects)
        raise ArgumentError, "Inbound effects must be an array" unless effects.is_a?(Array)
        raise ArgumentError, "Inbound effect count exceeds #{MAX_EFFECTS}" if effects.size > MAX_EFFECTS
        raise ArgumentError, "Inbound effect payload exceeds #{MAX_PLAINTEXT_BYTES} bytes" if
          JSON.generate(effects).bytesize > MAX_PLAINTEXT_BYTES

        effects.each { |effect| validate_effect!(effect) }
        effects
      end

      def append(effect)
        current_context.append(effect)
      end
      private_class_method :append

      def current_context
        ActiveSupport::IsolatedExecutionState[CONTEXT_KEY]
      end
      private_class_method :current_context

      def perform_later(job, arguments, keyword_arguments)
        return job.perform_later(*arguments) if keyword_arguments.empty?

        job.perform_later(*arguments, **keyword_arguments)
      end
      private_class_method :perform_later

      def dispatch_job(effect)
        job = effect.fetch("job_class").safe_constantize
        unless job && job.respond_to?(:perform_later) && ACTIVE_JOB_ALLOWLIST.include?(job.name.to_s)
          raise ArgumentError, "Durable inbound ActiveJob class is unavailable or disallowed"
        end

        arguments = deserialize_job_arguments(effect)
        return :discarded unless arguments

        result = job.perform_later(*arguments)
        raise EnqueueError, "Durable inbound ActiveJob enqueue failed" if result == false

        result
      end
      private_class_method :dispatch_job

      def deserialize_job_arguments(effect)
        ActiveJob::Arguments.deserialize(effect.fetch("arguments"))
      rescue ActiveJob::DeserializationError
        # The referenced GlobalID disappeared before enqueue. Retrying cannot
        # reconstruct it, so consume the allowlisted effect without blocking
        # later effects or replaying the inbound civic handler.
        nil
      end
      private_class_method :deserialize_job_arguments

      # Use the job's own serializer before the effect reaches the receipt.
      # Provider reply/auth jobs seal their raw recipient and copy here, so the
      # durable effect envelope contains only their purpose-isolated ciphertext.
      def serialize_job_arguments(job, arguments, keyword_arguments)
        raw_arguments = arguments.dup
        raw_arguments << Hash.ruby2_keywords_hash(keyword_arguments) unless keyword_arguments.empty?
        active_job_class = job.is_a?(Class) && job <= ActiveJob::Base
        return ActiveJob::Arguments.serialize(raw_arguments) unless active_job_class

        instance = job.new(*raw_arguments)
        instance.serialize.fetch("arguments")
      rescue NoMethodError, TypeError
        raise ArgumentError, "Durable inbound effect requires an ActiveJob class"
      end
      private_class_method :serialize_job_arguments

      def dispatch_cache_write(effect, cache:)
        options = deserialize_options(effect.fetch("options"))
        remaining = remaining_ttl(effect, unit: :seconds)
        return :expired if remaining == :expired

        options[:expires_in] = remaining if remaining
        (cache || Rails.cache).write(
          effect.fetch("key"),
          deserialize_value(effect.fetch("value")),
          **options
        )
      end
      private_class_method :dispatch_cache_write

      def dispatch_redis_set(effect, redis:)
        options = deserialize_options(effect.fetch("options"))
        ttl_option = effect["ttl_option"]&.to_sym
        if ttl_option
          remaining = remaining_ttl(effect, unit: ttl_option == :px ? :milliseconds : :seconds)
          return :expired if remaining == :expired

          options[ttl_option] = remaining
        end
        (redis || default_redis).set(
          effect.fetch("key"),
          deserialize_value(effect.fetch("value")),
          **options
        )
      end
      private_class_method :dispatch_redis_set

      def dispatch_redis_delete(effect, redis:)
        (redis || default_redis).del(*effect.fetch("keys"))
      end
      private_class_method :dispatch_redis_delete

      def dispatch_redis_eval(effect, redis:)
        registry = REDIS_SCRIPT_REGISTRY.fetch(effect.fetch("script_id"))
        argv = deserialize_value(effect.fetch("argv"))
        remaining = remaining_ttl(effect, unit: registry.fetch(:ttl_unit))
        return :expired if remaining == :expired

        argv[registry.fetch(:ttl_argv_index)] = remaining
        (redis || default_redis).eval(
          registry.fetch(:script).call,
          keys: effect.fetch("keys"),
          argv:
        )
      end
      private_class_method :dispatch_redis_eval

      def serialize_value(value)
        ActiveJob::Arguments.serialize([value]).first
      end
      private_class_method :serialize_value

      def deserialize_value(value)
        ActiveJob::Arguments.deserialize([value]).first
      end
      private_class_method :deserialize_value

      def serialize_options(options, allowlist:)
        normalized = options.to_h.transform_keys(&:to_s)
        unsupported = normalized.keys - allowlist
        raise ArgumentError, "Unsupported durable effect options: #{unsupported.sort.join(", ")}" if unsupported.any?

        serialize_value(normalized)
      end
      private_class_method :serialize_options

      def deserialize_options(options)
        deserialize_value(options).to_h.transform_keys(&:to_sym)
      end
      private_class_method :deserialize_options

      def attach_redis_set_deadline!(effect, options)
        ttl_options = options.keys.map(&:to_sym) & [:ex, :px]
        raise ArgumentError, "A Redis durable effect cannot use both EX and PX" if ttl_options.size > 1
        return if ttl_options.empty?

        ttl_option = ttl_options.first
        effect["ttl_option"] = ttl_option.to_s
        unit = ttl_option == :px ? :milliseconds : :seconds
        attach_deadline!(effect, options.fetch(ttl_option), unit:)
      end
      private_class_method :attach_redis_set_deadline!

      def attach_script_deadline!(effect, argv, registry)
        ttl = argv.fetch(registry.fetch(:ttl_argv_index))
        attach_deadline!(effect, ttl, unit: registry.fetch(:ttl_unit))
      end
      private_class_method :attach_script_deadline!

      def attach_deadline!(effect, ttl, unit:)
        multiplier = unit == :milliseconds ? 1 : 1000
        ttl_ms = Float(ttl) * multiplier
        raise ArgumentError, "Durable effect TTL must be positive" unless ttl_ms.positive? && ttl_ms.finite?

        effect["deadline_at_ms"] = ((Time.current.to_f * 1000) + ttl_ms).ceil
      rescue ArgumentError, TypeError
        raise ArgumentError, "Durable effect TTL is invalid"
      end
      private_class_method :attach_deadline!

      def attach_absolute_deadline!(effect, deadline)
        effect["deadline_at_ms"] = milliseconds_since_epoch(deadline).ceil
      rescue ArgumentError, TypeError
        raise ArgumentError, "Durable effect expiry is invalid"
      end
      private_class_method :attach_absolute_deadline!

      def milliseconds_since_epoch(value)
        time = value.to_time
        milliseconds = time.to_f * 1000
        raise ArgumentError unless milliseconds.finite?

        milliseconds
      rescue NoMethodError
        raise ArgumentError
      end
      private_class_method :milliseconds_since_epoch

      def remaining_ttl(effect, unit:)
        deadline = effect["deadline_at_ms"]
        return unless deadline

        remaining_ms = Integer(deadline) - (Time.current.to_f * 1000)
        return :expired unless remaining_ms.positive?

        divisor = unit == :milliseconds ? 1 : 1000
        remaining = (remaining_ms / divisor).floor
        remaining.positive? ? remaining : :expired
      rescue ArgumentError, TypeError
        raise ArgumentError, "Durable effect deadline is invalid"
      end
      private_class_method :remaining_ttl

      def bounded_key(key)
        value = key.to_s
        raise ArgumentError, "Durable effect key is blank" if value.empty?
        raise ArgumentError, "Durable effect key exceeds #{MAX_KEY_BYTES} bytes" if value.bytesize > MAX_KEY_BYTES

        value
      end
      private_class_method :bounded_key

      def validate_effect!(effect)
        raise ArgumentError, "Inbound effect must be an object" unless effect.is_a?(Hash)
        raise ArgumentError, "Inbound effect type is not allowed" unless EFFECT_TYPES.include?(effect["type"])

        send(EFFECT_VALIDATORS.fetch(effect.fetch("type")), effect)
      end
      private_class_method :validate_effect!

      def validate_active_job_effect!(effect)
        raise ArgumentError, "Inbound ActiveJob class is not allowed" unless
          ACTIVE_JOB_ALLOWLIST.include?(effect["job_class"])
        raise ArgumentError, "Inbound ActiveJob arguments are invalid" unless effect["arguments"].is_a?(Array)

        validate_deadline!(effect)
      end
      private_class_method :validate_active_job_effect!

      def validate_tombstone_effect!(effect)
        raise ArgumentError, "Inbound effect tombstone is invalid" unless effect == TOMBSTONE_EFFECT
      end
      private_class_method :validate_tombstone_effect!

      def validate_keyed_effect!(effect)
        bounded_key(effect.fetch("key"))
        effect.fetch("value")
        effect.fetch("options")
        validate_deadline!(effect)
      end
      private_class_method :validate_keyed_effect!

      def validate_redis_delete_effect!(effect)
        validate_redis_keys!(effect.fetch("keys"), label: "delete")
      end
      private_class_method :validate_redis_delete_effect!

      def validate_redis_eval_effect!(effect)
        raise ArgumentError, "Inbound Redis script is not allowed" unless
          REDIS_SCRIPT_REGISTRY.has_key?(effect["script_id"])

        validate_redis_keys!(effect.fetch("keys"), label: "script")
        effect.fetch("argv")
        validate_deadline!(effect, required: true)
      end
      private_class_method :validate_redis_eval_effect!

      def validate_redis_keys!(keys, label:)
        raise ArgumentError, "Inbound Redis #{label} keys are invalid" unless
          keys.is_a?(Array) && keys.any? && keys.size <= MAX_REDIS_KEYS

        keys.each { |key| bounded_key(key) }
      end
      private_class_method :validate_redis_keys!

      def validate_deadline!(effect, required: false)
        deadline = effect["deadline_at_ms"]
        raise ArgumentError, "Inbound durable effect deadline is missing" if required && deadline.nil?
        return if deadline.nil?

        Integer(deadline)
      rescue ArgumentError, TypeError
        raise ArgumentError, "Inbound durable effect deadline is invalid"
      end
      private_class_method :validate_deadline!

      def default_redis
        Redis.new(url: Decidim::Bih::RedisEndpoint.url)
      end
      private_class_method :default_redis
    end
  end
end

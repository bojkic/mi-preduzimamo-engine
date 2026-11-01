# frozen_string_literal: true

require "test_helper"
require "digest"
require "json"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/turn_budget"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/understand"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/understanding_cache"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The cache stands in for exactly one provider call. These tests prove
        # its scope (tenant, actor, text, projection, prompt, locale), what it
        # refuses to touch, and that its failures never reach the citizen.
        class UnderstandingCacheTest < Minitest::Test
          NOW = Time.utc(2026, 9, 13, 10, 0)
          CONVERSATION_KEY = ("a" * 64).freeze

          VALID_RESPONSE = {
            "action" => "ask_information", "topic" => "waste",
            "entities" => { "query" => "Ledinci" }, "operation" => "start",
            "needs_clarification" => false, "secondary" => nil, "locale" => "sr"
          }.freeze

          CLARIFICATION = VALID_RESPONSE.merge(
            "action" => "help", "topic" => "unknown", "entities" => {}, "operation" => "clarify", "needs_clarification" => true
          ).freeze

          class FakeRedis
            attr_reader :values, :ttls, :operations

            def initialize(failure: nil)
              @values = {}
              @ttls = {}
              @operations = []
              @failure = failure
            end

            def get(key)
              operations << [:get, key]
              raise @failure if @failure

              values[key]
            end

            # Mirrors Redis#set's keyword, so the fake accepts the real call.
            def set(key, value, ex: nil) # rubocop:disable Naming/MethodParameterName
              operations << [:set, key]
              raise @failure if @failure

              values[key] = value
              ttls[key] = ex
              "OK"
            end
          end

          class FakeClient
            attr_accessor :response
            attr_reader :calls

            def initialize(response: VALID_RESPONSE)
              @response = response
              @calls = []
            end

            def configured? = true

            def generate_content(**arguments)
              calls << arguments
              response
            end
          end

          class FakeLogger
            attr_reader :lines

            def initialize
              @lines = []
            end

            [:debug, :info, :warn, :error].each do |level|
              define_method(level) { |line| lines << [level, line] }
            end
          end

          Message = Struct.new(:text, :trusted_context, :cancel, :credential_handled, :trusted_button, :safety_signal, keyword_init: true) do
            alias_method :cancel?, :cancel
            alias_method :credential_handled?, :credential_handled
            alias_method :trusted_button?, :trusted_button
            alias_method :safety_signal?, :safety_signal
          end

          EMPTY_PROJECTION = {
            "active_task" => nil, "topic" => "unknown", "pending_slot" => nil, "entities" => {}, "locale" => "sr"
          }.freeze

          def setup
            @redis = FakeRedis.new
            @client = FakeClient.new
            @cache = UnderstandingCache.new(redis: @redis)
            @understand = Understand.new(client: @client, wall_clock: -> { NOW }, cache: @cache)
          end

          def scope(organization_id: 1, actor_id: 12)
            Contracts::TrustedContext.new(organization_id:, conversation_key: CONVERSATION_KEY, actor_id:, now: NOW)
          end

          def turn(text, organization_id: 1, actor_id: 12, **flags)
            Message.new(text:, trusted_context: scope(organization_id:, actor_id:), **flags)
          end

          def budget
            TurnBudget.new(timeout: 10)
          end

          def call(message, state: {}, history: [], understand: @understand)
            understand.call(message:, state:, history:, deadline: budget)
          end

          # One complete, cacheable turn; each test overrides the component it probes.
          def key_for(cache: @cache, **overrides)
            defaults = { scope: scope, text: "Kada se odvozi smeće u Ledincima?", projection: EMPTY_PROJECTION,
                         prompt_fingerprint: "prompt-a", locale: "sr", state: {} }
            cache.key_for(**defaults, **overrides)
          end

          # --- key composition ---------------------------------------------

          def test_key_is_the_documented_tenant_scoped_digest
            key = key_for(scope: scope(organization_id: 7, actor_id: 12))

            material = JSON.generate([7, "actor:12", "kada se odvozi smece u ledincima", EMPTY_PROJECTION, Contracts::VERSION, "prompt-a", "sr"])
            assert_equal "#{UnderstandingCache::KEY_PREFIX}:7:#{Digest::SHA256.hexdigest(material)}", key
            assert_equal "decidim:bih:concierge:understanding:v1", UnderstandingCache::KEY_PREFIX
            assert_equal 600, UnderstandingCache::TTL_SECONDS
          end

          def test_key_folds_script_and_punctuation_but_keeps_every_scope_component_apart
            base = key_for
            assert_equal base, key_for(text: "kada se odvozi SMECE u ledincima")
            assert_equal base, key_for(text: "Када се одвози смеће у Лединцима"), "Cyrillic folds to the same text; the locale component keeps the scripts apart"

            refute_equal base, key_for(scope: scope(organization_id: 2))
            refute_equal base, key_for(scope: scope(actor_id: 13))
            refute_equal base, key_for(scope: scope(actor_id: nil))
            refute_equal base, key_for(text: "Kada se odvozi smeće u Dvorovima?")
            refute_equal base, key_for(projection: EMPTY_PROJECTION.merge("topic" => "waste"))
            refute_equal base, key_for(projection: EMPTY_PROJECTION.merge("lexicon_topics" => %w(waste)))
            refute_equal base, key_for(prompt_fingerprint: "prompt-b")
            refute_equal base, key_for(locale: "sr-Cyrl")
          end

          def test_no_key_when_disabled_unscoped_too_short_or_a_report_is_in_progress
            assert_nil key_for(cache: UnderstandingCache.new(redis: @redis, enabled: false))
            assert_nil key_for(scope: nil)
            assert_nil key_for(scope: { organization_id: 1, actor_id: 12 }), "only a TrustedContext is a scope"
            assert_nil key_for(text: "ok")
            assert_nil key_for(text: "22")
            assert_nil key_for(text: "Не")
            assert_nil key_for(state: { "draft" => { "reference" => "x" * 16, "revision" => 0, "expires_at" => 1.0 } })
            assert_nil key_for(state: { "report_handoff_offered" => true })
            refute_nil key_for(state: { "draft" => nil, "report_handoff_offered" => false })
            refute_nil key_for(text: "Voda")
          end

          # --- storage behaviour -------------------------------------------

          def test_write_sets_the_ttl_and_read_returns_the_parsed_understanding
            key = key_for
            understanding = Contracts::Understanding.parse(VALID_RESPONSE)

            assert @cache.write(key, understanding)
            assert_equal 600, @redis.ttls.fetch(key)
            assert_equal VALID_RESPONSE, JSON.parse(@redis.values.fetch(key)), "the stored payload is the shape Understanding.parse accepts"
            assert_equal understanding, @cache.read(key)
          end

          def test_clarifications_are_never_written_and_never_returned
            key = key_for

            refute @cache.write(key, Contracts::Understanding.parse(CLARIFICATION))
            assert_empty @redis.values

            @redis.values[key] = JSON.generate(CLARIFICATION)
            assert_nil @cache.read(key)
          end

          def test_storage_failures_corrupt_and_oversized_values_are_a_miss_and_never_raise
            logger = FakeLogger.new
            failing = UnderstandingCache.new(redis: FakeRedis.new(failure: Redis::CannotConnectError.new("redis://secret@host")), logger:)
            key = key_for

            assert_nil failing.read(key)
            refute failing.write(key, Contracts::Understanding.parse(VALID_RESPONSE))
            assert_equal 2, (logger.lines.count { |level, line| level == :warn && line == "[MilicaUnderstandCache] miss error=Redis::CannotConnectError" })
            refute(logger.lines.any? { |_, line| line.include?("secret") })

            @redis.values[key] = "{not json"
            assert_nil @cache.read(key)
            @redis.values[key] = JSON.generate(VALID_RESPONSE.merge("action" => "grant_admin"))
            assert_nil @cache.read(key)
            @redis.values[key] = JSON.generate(VALID_RESPONSE.merge("entities" => { "description" => "x" * 9_000 }))
            assert_nil @cache.read(key)
          end

          def test_the_environment_flag_is_off_by_default_and_accepts_only_one_and_true
            refute UnderstandingCache.from_environment(env: {}).enabled?
            refute UnderstandingCache.from_environment(env: { "MILICA_UNDERSTANDING_CACHE" => "0" }).enabled?
            refute UnderstandingCache.from_environment(env: { "MILICA_UNDERSTANDING_CACHE" => "yes" }).enabled?
            assert UnderstandingCache.from_environment(env: { "MILICA_UNDERSTANDING_CACHE" => "1" }).enabled?
            assert UnderstandingCache.from_environment(env: { "MILICA_UNDERSTANDING_CACHE" => "true" }).enabled?
            assert_equal "MILICA_UNDERSTANDING_CACHE", UnderstandingCache::ENVIRONMENT_FLAG
          end

          def test_understand_defaults_to_the_environment_cache
            skip "flag set in this environment" if ENV.has_key?("MILICA_UNDERSTANDING_CACHE")

            cache = Understand.new(client: @client, wall_clock: -> { NOW }).instance_variable_get(:@cache)
            assert_instance_of UnderstandingCache, cache
            refute cache.enabled?
          end

          # --- through Understand -----------------------------------------

          def test_identical_turn_twice_makes_one_model_call
            first = call(turn("Kada se odvozi smeće u Ledincima?"))
            second = call(turn("Kada se odvozi smeće u Ledincima?"))

            assert_equal 1, @client.calls.size
            assert_equal first, second
            assert_equal "waste", second.topic
            assert_equal({ "query" => "Ledinci" }, second.entities)
            assert_equal [:get, :set, :get], @redis.operations.map(&:first)
          end

          def test_history_is_not_part_of_the_key
            history = [{ "user" => "Pozdrav", "bot" => "Zdravo", "at" => NOW.to_f }]
            call(turn("Kada se odvozi smeće u Ledincima?"), history: [])
            call(turn("Kada se odvozi smeće u Ledincima?"), history:)

            assert_equal 1, @client.calls.size
          end

          def test_a_different_organization_or_actor_never_shares_an_entry
            call(turn("Kada se odvozi smeće u Ledincima?", organization_id: 1, actor_id: 12))
            call(turn("Kada se odvozi smeće u Ledincima?", organization_id: 2, actor_id: 12))
            call(turn("Kada se odvozi smeće u Ledincima?", organization_id: 1, actor_id: 13))
            call(turn("Kada se odvozi smeće u Ledincima?", organization_id: 1, actor_id: nil))

            assert_equal 4, @client.calls.size
            assert_equal 4, @redis.values.size
            assert(@redis.values.keys.count { |key| key.start_with?("#{UnderstandingCache::KEY_PREFIX}:1:") } == 3)
            assert(@redis.values.keys.count { |key| key.start_with?("#{UnderstandingCache::KEY_PREFIX}:2:") } == 1)
          end

          def test_a_changed_state_projection_or_prompt_fingerprint_is_a_miss
            call(turn("Ledinci"), state: {})
            call(turn("Ledinci"), state: { "active_task" => "ask_information", "topic" => "waste", "pending_slot" => "query", "entities" => {}, "locale" => "sr" })
            assert_equal 2, @client.calls.size

            other_prompt = Understand.new(
              client: @client, wall_clock: -> { NOW }, cache: @cache,
              configuration: { "version" => 1, "max_understanding_seconds" => 6.0, "max_history_turns" => 6,
                               "max_history_text_length" => 1000, "system_instruction" => "Classify only." }
            )
            refute_equal @understand.prompt_fingerprint, other_prompt.prompt_fingerprint
            call(turn("Ledinci"), state: {}, understand: other_prompt)
            assert_equal 3, @client.calls.size
            call(turn("Ledinci"), state: {}, understand: other_prompt)
            assert_equal 3, @client.calls.size
          end

          def test_the_prompt_fingerprint_is_the_digest_of_the_effective_instruction_including_the_lexicon
            call(turn("Kada se odvozi smeće u Ledincima?"))
            instruction = @client.calls.fetch(0).fetch(:system_instruction)

            assert_includes instruction, "Local words", "the shipped configuration carries a lexicon appendix"
            assert_equal Digest::SHA256.hexdigest(instruction), @understand.prompt_fingerprint
          end

          def test_secret_like_safety_and_trusted_button_turns_never_read_or_write_the_cache
            [
              turn("Moj verifikacioni kod je 123456"),
              turn("Moja lozinka je hunter2"),
              turn("nastavi dalje", credential_handled: true),
              turn("izaberi ovo", trusted_button: true),
              turn("hitno je", safety_signal: true)
            ].each do |bypassed|
              result = call(bypassed)
              assert result.needs_clarification
            end

            assert_empty @client.calls
            assert_empty @redis.operations
          end

          def test_a_pending_report_draft_or_handoff_offer_bypasses_the_cache
            report = { "active_task" => "report_problem", "topic" => "roads", "pending_slot" => "description",
                       "entities" => { "street" => "Majevička" }, "locale" => "sr" }
            drafting = report.merge("draft" => { "reference" => "r" * 16, "revision" => 0, "expires_at" => NOW.to_f + 60 })
            offered = report.merge("report_handoff_offered" => true)

            2.times { call(turn("Rupa na putu je velika"), state: drafting) }
            2.times { call(turn("Rupa na putu je velika"), state: offered) }

            assert_equal 4, @client.calls.size
            assert_empty @redis.operations
          end

          def test_too_short_or_unscoped_turns_bypass_the_cache
            2.times { call(turn("Da")) }
            2.times { call("Kada se odvozi smeće u Ledincima?") }
            2.times { call(Message.new(text: "Kada se odvozi smeće u Ledincima?", trusted_context: nil)) }

            assert_equal 6, @client.calls.size
            assert_empty @redis.operations
          end

          def test_a_model_clarification_is_not_cached
            @client.response = CLARIFICATION

            2.times { assert call(turn("Nešto nejasno ovdje")).needs_clarification }

            assert_equal 2, @client.calls.size
            assert_empty @redis.values
            assert_equal [:get, :get], @redis.operations.map(&:first)
          end

          def test_a_hit_still_applies_the_citizen_script_normalisation
            @client.response = VALID_RESPONSE.merge("locale" => "sr-Cyrl")

            first = call(turn("Kada se odvozi smeće u Ledincima?"))
            second = call(turn("Kada se odvozi smeće u Ledincima?"))

            assert_equal 1, @client.calls.size
            assert_equal "sr-Cyrl", JSON.parse(@redis.values.values.fetch(0)).fetch("locale"), "the model's own reply is what is cached"
            assert_equal "sr", first.locale
            assert_equal "sr", second.locale, "a clearly Latin message wins over the cached model locale, exactly as on a miss"
          end

          def test_a_redis_failure_means_the_model_is_called_and_nothing_raises
            failing = UnderstandingCache.new(redis: FakeRedis.new(failure: Redis::TimeoutError.new("slow")))
            understand = Understand.new(client: @client, wall_clock: -> { NOW }, cache: failing)

            result = call(turn("Kada se odvozi smeće u Ledincima?"), understand:)
            call(turn("Kada se odvozi smeće u Ledincima?"), understand:)

            assert_equal "waste", result.topic
            refute result.needs_clarification
            assert_equal 2, @client.calls.size
          end

          def test_a_disabled_cache_never_touches_redis
            redis = FakeRedis.new(failure: RuntimeError.new("redis must not be reached"))
            understand = Understand.new(client: @client, wall_clock: -> { NOW }, cache: UnderstandingCache.new(redis:, enabled: false))

            2.times { call(turn("Kada se odvozi smeće u Ledincima?"), understand:) }

            assert_equal 2, @client.calls.size
            assert_empty redis.operations
          end

          def test_a_hit_is_logged_at_debug_without_citizen_text
            logger = FakeLogger.new
            cache = UnderstandingCache.new(redis: @redis, logger:)
            understand = Understand.new(client: @client, wall_clock: -> { NOW }, cache:)

            2.times { call(turn("Kada se odvozi smeće u Ledincima?"), understand:) }

            assert_equal [[:debug, "[MilicaUnderstandCache] hit"]], logger.lines
            refute_includes logger.lines.join, "Ledinci"
          end

          def test_provider_and_budget_failures_are_unchanged_and_write_nothing
            unconfigured = Class.new(FakeClient) { def configured? = false }.new
            understand = Understand.new(client: unconfigured, wall_clock: -> { NOW }, cache: @cache)
            error = assert_raises(Understand::ProviderUnavailable) { call(turn("Kada se odvozi smeće u Ledincima?"), understand:) }
            assert_equal "unconfigured", error.reason

            @client.response = { "invalid" => true }
            error = assert_raises(Understand::ProviderUnavailable) { call(turn("Kada se odvozi smeće u Ledincima?")) }
            assert_equal "malformed", error.reason

            assert_empty @redis.values
          end
        end
      end
    end
  end
end

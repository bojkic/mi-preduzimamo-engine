# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/state_store"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The contract for the RESERVED bounded emergency continuity key.
        #
        # Task 0 reserves it; Task 2 is its only writer; Task 4 restructures the
        # state machinery around it and must keep this green. Every rule here is
        # a promise made to the citizen in an emergency: the context is short,
        # bounded, tied to one topic, one actor and one organization, and it
        # disappears the moment any of that stops being true.
        class SafetyContextContractTest < Minitest::Test
          NOW = Time.utc(2026, 9, 14, 12)
          KEY = StateStore::SAFETY_CONTEXT_KEY

          class FakeRedis
            attr_reader :values

            def initialize
              @values = {}
            end

            def get(key) = @values[key]

            def del(key)
              @values.delete(key)
              1
            end

            def eval(script, keys:, argv:)
              raise "Unexpected script" unless script == StateStore::WRITE_SCRIPT

              stored = @values[keys.first]
              version = stored ? JSON.parse(stored).fetch("version") : 0
              return 0 unless version == argv.first

              @values[keys.first] = argv[1]
              1
            end
          end

          def setup
            @redis = FakeRedis.new
            @store = StateStore.new(redis: @redis)
            @context = context_for
          end

          def context_for(organization_id: 1, actor_id: 7, conversation_key: "a" * 64, now: NOW)
            Contracts::TrustedContext.new(organization_id:, conversation_key:, actor_id:, now:)
          end

          def safety_context(**overrides)
            { "kind" => "immediate_danger", "topic" => "police", "opened_at" => NOW.to_f,
              "expires_at" => NOW.to_f + 300, "turns" => 1 }.merge(overrides)
          end

          def state_with(context: @context, safety: safety_context, topic: "police", **overrides)
            @store.empty_state(context).merge("topic" => topic, KEY => safety).merge(overrides)
          end

          def save(state, context: @context, expected_version: 0)
            @store.write(context:, state:, expected_version:)
          end

          def test_the_key_is_reserved_versioned_empty_and_outside_the_suspended_task
            assert_equal "safety_context_v1", KEY
            assert_includes StateStore::STATE_KEYS, KEY
            refute_includes StateStore::TASK_KEYS, KEY, "a suspended task must never carry emergency continuity"
            assert_nil @store.empty_state(@context).fetch(KEY)
            assert_nil @store.read(context: @context).fetch(KEY)
          end

          # Task 0 asserted that NOTHING wrote the key yet. Task 2 is its one
          # writer, and this now pins which file that is: a second writer in
          # the dialogue is the thing this contract exists to prevent.
          def test_exactly_one_dialogue_file_writes_the_key
            sources = Dir[File.expand_path("../../../../../../app/services/decidim/bih/concierge/**/*.rb", __dir__)]
            writers = sources.reject { |path| path.end_with?("state_store.rb") }
                             .select { |path| File.read(path).match?(/SAFETY_CONTEXT_KEY|#{KEY}/) }
                             .map { |path| File.basename(path) }

            assert_equal ["emergency_stage.rb"], writers, "Task 2's emergency stage is the only writer of #{KEY}"
          end

          def test_a_well_formed_context_survives_a_write_and_read
            assert_equal :saved, save(state_with)
            stored = @store.read(context: @context)

            assert_equal safety_context, stored.fetch(KEY)
          end

          # Lifetime.
          def test_an_expired_context_is_dropped_on_read
            assert_equal :saved, save(state_with(safety: safety_context("expires_at" => NOW.to_f + 60)))

            assert_nil @store.read(context: context_for(now: NOW + 61)).fetch(KEY)
          end

          def test_a_context_may_not_outlive_the_bounded_window
            over = StateStore::SAFETY_CONTEXT_TTL + 1

            assert_equal 600, StateStore::SAFETY_CONTEXT_TTL
            assert_nil @store.validate(context: @context, state: state_with(safety: safety_context("expires_at" => NOW.to_f + over))).fetch(KEY)
            assert_nil @store.validate(context: @context, state: state_with(safety: safety_context("opened_at" => NOW.to_f + 60))).fetch(KEY),
                       "a context cannot have been opened in the future"
          end

          def test_a_context_may_not_outlive_the_conversation_state
            state = state_with("expires_at" => NOW.to_f + 120)

            assert_nil @store.validate(context: @context, state:).fetch(KEY)
          end

          def test_a_context_is_dropped_once_it_has_followed_too_many_turns
            assert_equal 3, StateStore::SAFETY_CONTEXT_MAX_TURNS
            assert_nil @store.validate(context: @context, state: state_with(safety: safety_context("turns" => 4))).fetch(KEY)
            refute_nil @store.validate(context: @context, state: state_with(safety: safety_context("turns" => 3))).fetch(KEY)
          end

          # Clearing.
          def test_a_real_topic_change_clears_the_context
            moved = state_with(topic: "waste", safety: safety_context("topic" => "police"))

            assert_nil @store.validate(context: @context, state: moved).fetch(KEY)
            refute_nil @store.validate(context: @context, state: state_with(topic: "police")).fetch(KEY)
          end

          def test_an_explicit_resolution_clears_the_context_and_nothing_restores_it
            assert_equal :saved, save(state_with)
            resolved = @store.read(context: @context).merge(KEY => nil)

            assert_equal :saved, save(resolved, expected_version: 1)
            assert_nil @store.read(context: @context).fetch(KEY)
          end

          def test_clearing_the_conversation_removes_the_context_with_it
            assert_equal :saved, save(state_with)
            @store.clear(context: @context)

            assert_nil @store.read(context: @context).fetch(KEY)
          end

          # Actor and tenant scope.
          def test_another_actor_organization_or_conversation_never_sees_the_context
            assert_equal :saved, save(state_with)

            [context_for(actor_id: 8), context_for(organization_id: 2), context_for(conversation_key: "b" * 64),
             context_for(actor_id: nil)].each do |other|
              assert_nil @store.read(context: other).fetch(KEY), "emergency continuity leaked to #{other.inspect}"
            end
          end

          # Malformed input is dropped, never raised: a continuity hint must not
          # be able to destroy the conversation around it.
          def test_a_malformed_context_is_dropped_without_losing_the_conversation
            [
              "not a hash", {}, safety_context("kind" => "Immediate Danger"), safety_context("kind" => ""),
              safety_context("turns" => "1"), safety_context("opened_at" => "soon"),
              safety_context.merge("extra" => "x"), safety_context.except("topic")
            ].each do |malformed|
              state = @store.validate(context: @context, state: state_with(safety: malformed))

              assert_nil state.fetch(KEY), "#{malformed.inspect} should have been dropped"
              assert_equal "police", state.fetch("topic"), "the conversation must survive a malformed context"
            end
          end

          def test_a_state_saved_before_the_key_existed_still_loads
            older = @store.empty_state(@context).except(KEY)

            assert_equal :saved, save(older)
            assert_nil @store.read(context: @context).fetch(KEY)
          end
        end
      end
    end
  end
end

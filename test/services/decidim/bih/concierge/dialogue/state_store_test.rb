# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/state_store"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class StateStoreTest < Minitest::Test
          NOW = Time.utc(2026, 9, 5, 12)

          class FakeRedis
            attr_reader :values, :deleted

            def initialize
              @values = {}
              @deleted = []
            end

            def get(key) = values[key]

            def del(key)
              deleted << key
              values.delete(key)
            end

            def eval(script, keys:, argv:)
              if script == StateStore::RESET_SCRIPT
                return 0 unless values[keys.first] == argv.first

                values.delete(keys.first)
                return 1
              end

              stored = values[keys.first]
              version = stored ? JSON.parse(stored).fetch("version") : 0
              return 0 unless version == argv.first

              values[keys.first] = argv[1]
              1
            end
          end

          def context(organization_id: 1, actor_id: nil, now: NOW)
            Contracts::TrustedContext.new(organization_id:, actor_id:, conversation_key: "a" * 64, now:)
          end

          def test_cas_rejects_stale_turn_and_preserves_latest_state
            redis = FakeRedis.new
            store = StateStore.new(redis:)
            initial = store.read(context: context)
            first = initial.merge("active_task" => "report_problem", "topic" => "waste")

            assert_equal :saved, store.write(context: context, state: first, expected_version: 0)
            assert_equal :conflict, store.write(context: context, state: initial, expected_version: 0)
            assert_equal :invalid, store.write(context: context, state: initial, expected_version: 1)
            assert_equal "report_problem", store.read(context: context).fetch("active_task")
            assert_equal 1, store.read(context: context).fetch("version")
          end

          def test_model_led_frame_uses_same_cas_and_drops_invalid_optional_memory
            store = StateStore.new(redis: FakeRedis.new)
            initial = store.read(context: context)
            frame = ConversationFrame.empty(context: context).append(message: "Do Janje?", answer: "Odakle?", context: context)
            state = initial.merge(ConversationFrame::KEY => frame.value)
            assert_equal :saved, store.write(context: context, state: state, expected_version: 0)
            assert_equal frame.value, store.read(context: context).fetch(ConversationFrame::KEY)
            assert_equal :conflict, store.write(context: context, state: initial, expected_version: 0)
            assert_nil store.validate(context: context, state: initial.except(ConversationFrame::KEY)).fetch(ConversationFrame::KEY)
            assert_nil store.validate(context: context, state: initial.merge(ConversationFrame::KEY => { "private" => "no" })).fetch(ConversationFrame::KEY)
            refute_includes StateStore::TASK_KEYS, ConversationFrame::KEY
          end

          def test_old_state_without_optional_prior_evidence_normalizes_to_nil
            store = StateStore.new(redis: FakeRedis.new)
            old = store.empty_state(context).merge("active_task" => "ask_information", "topic" => "water").except("prior_evidence")

            normalized = store.validate(context: context, state: old)

            assert_nil normalized.fetch("prior_evidence")
            assert_equal "ask_information", normalized.fetch("active_task")
          end

          def test_conversation_slot_reader_accepts_old_state_and_preserves_bounded_new_slot
            redis = FakeRedis.new
            store = StateStore.new(redis:)
            old = store.empty_state(context).except(ConversationSlots::KEY)
            assert_nil store.validate(context: context, state: old).fetch(ConversationSlots::KEY)

            slot = ConversationSlots.empty.merge(
              "location" => { "kind" => "named", "label" => "Janja", "place_id" => "komsiluk-janja", "at" => NOW.to_f }
            )
            candidate = old.merge(ConversationSlots::KEY => slot)
            assert_equal :saved, store.write(context: context, state: candidate, expected_version: 0)
            assert_equal slot, store.read(context: context).fetch(ConversationSlots::KEY)
            assert_equal :invalid, store.write(context: context, state: candidate.merge("unknown_slot" => true), expected_version: 0)
            assert_equal slot, store.read(context: context).fetch(ConversationSlots::KEY)
            refute_includes StateStore::TASK_KEYS, ConversationSlots::KEY
          end

          def test_corrupt_optional_slot_is_dropped_without_erasing_other_state
            store = StateStore.new(redis: FakeRedis.new)
            state = store.empty_state(context).merge("active_task" => "ask_information", "topic" => "transport",
                                                     ConversationSlots::KEY => { "raw_coordinates" => [44.7, 19.2] })
            normalized = store.validate(context: context, state: state)

            assert_nil normalized.fetch(ConversationSlots::KEY)
            assert_equal "transport", normalized.fetch("topic")
          end

          def test_resume_offer_marker_is_additive_and_strictly_boolean
            store = StateStore.new(redis: FakeRedis.new)
            empty = store.empty_state(context)

            assert_equal false, empty.fetch("resume_offered")
            assert_equal false, store.validate(context: context, state: empty.except("resume_offered")).fetch("resume_offered")
            assert_equal true, store.validate(context: context, state: empty.merge("resume_offered" => true)).fetch("resume_offered")
            assert_raises(Contracts::Invalid) { store.validate(context: context, state: empty.merge("resume_offered" => "yes")) }
            assert_equal :invalid, store.write(context: context, state: empty.merge("resume_offered" => nil), expected_version: 0)
            refute_includes StateStore::TASK_KEYS, "resume_offered", "the marker belongs to the conversation, not to a suspended task"
          end

          def test_legacy_report_handoff_marker_is_additive_for_active_and_suspended_tasks
            store = StateStore.new(redis: FakeRedis.new)
            report = store.empty_state(context).merge(
              "active_task" => "report_problem", "topic" => "roads", "pending_slot" => "query", "clarification_count" => 2,
              "entities" => { "description" => "Oštećen trotoar", "area_query" => "Naselje Primjer" },
              "entity_provenance" => { "description" => "citizen", "area_query" => "citizen" }
            ).except("report_handoff_offered")
            report["suspended_task"] = report.slice(*StateStore::TASK_KEYS)

            normalized = store.validate(context: context, state: report)
            assert_equal true, normalized.fetch("report_handoff_offered")
            assert_equal true, normalized.dig("suspended_task", "report_handoff_offered")
            assert_equal false, store.validate(context: context, state: report.merge("report_handoff_offered" => false)).fetch("report_handoff_offered")
            incomplete = report.merge("entities" => { "description" => "Oštećen trotoar" }, "entity_provenance" => { "description" => "citizen" })
            assert_equal false, store.validate(context: context, state: incomplete).fetch("report_handoff_offered")
            assert_raises(Contracts::Invalid) { store.validate(context: context, state: report.merge("report_handoff_offered" => "yes")) }
            assert_raises(Contracts::Invalid) do
              store.validate(context: context, state: report.merge("active_task" => "ask_information", "report_handoff_offered" => true))
            end
          end

          def test_organization_and_clear_are_scoped_away_from_otp
            redis = FakeRedis.new
            redis.values["bih:viber:state:1:opaque"] = "awaiting_code"
            store = StateStore.new(redis:)
            state = store.read(context: context).merge("active_task" => "ask_information")
            store.write(context: context, state:, expected_version: 0)

            assert_nil store.read(context: context(organization_id: 2)).fetch("active_task")
            assert store.clear(context: context)
            assert_equal "awaiting_code", redis.values.fetch("bih:viber:state:1:opaque")
            assert(redis.deleted.all? { |key| key.start_with?(StateStore::KEY_PREFIX) })
          end

          def test_expired_future_or_unknown_schema_state_cannot_resume
            %w(schema_version expires_at updated_at).each do |field|
              redis = FakeRedis.new
              store = StateStore.new(redis:)
              state = store.read(context: context)
              state[field] = { "schema_version" => 99, "expires_at" => NOW.to_f, "updated_at" => NOW.to_f + 1 }.fetch(field)

              assert_equal :invalid, store.write(context: context, state:, expected_version: 0)
            end
          end

          def test_expired_cache_state_is_not_returned_as_active
            redis = FakeRedis.new
            store = StateStore.new(redis:)
            state = store.read(context: context).merge("active_task" => "report_problem")
            store.write(context: context, state:, expected_version: 0)

            assert_nil store.read(context: context(now: NOW + 1800)).fetch("active_task")
            fresh = store.read(context: context(now: NOW + 1800))
            assert_equal :saved, store.write(context: context(now: NOW + 1800), state: fresh, expected_version: 0)
          end

          def test_malformed_state_is_removed_without_blocking_a_fresh_turn
            redis = FakeRedis.new
            store = StateStore.new(redis:)
            store.write(context: context, state: store.empty_state(context), expected_version: 0)
            redis.values[redis.values.keys.first] = "{broken"

            fresh = store.read(context: context)
            assert_equal 0, fresh.fetch("version")
            assert_equal :saved, store.write(context: context, state: fresh, expected_version: 0)
          end

          def test_private_state_cannot_cross_sign_in_or_account_switch
            store = StateStore.new(redis: FakeRedis.new)
            state = store.empty_state(context).merge("active_task" => "report_status")
            store.write(context: context(actor_id: 10), state:, expected_version: 0)

            assert_nil store.read(context: context).fetch("active_task")
            assert_nil store.read(context: context(actor_id: 11)).fetch("active_task")
            assert_equal "report_status", store.read(context: context(actor_id: 10)).fetch("active_task")
          end

          def test_reset_of_invalid_value_cannot_delete_a_concurrent_valid_turn
            redis = FakeRedis.new
            store = StateStore.new(redis:)
            current = store.empty_state(context).merge("active_task" => "report_status", "version" => 7)
            store.write(context: context, state: store.empty_state(context), expected_version: 0)
            redis.values[redis.values.keys.first] = "invalid json"
            redis.define_singleton_method(:eval) do |script, keys:, argv:|
              values[keys.first] = JSON.generate(current) if script == StateStore::RESET_SCRIPT
              super(script, keys:, argv:)
            end

            assert_equal 7, store.read(context: context).fetch("version")
            assert_equal "report_status", store.read(context: context).fetch("active_task")
          end

          def test_suspended_state_and_drafts_have_no_unvalidated_escape_hatch
            store = StateStore.new(redis: FakeRedis.new)
            state = store.empty_state(context)
            [{ "suspended_task" => { "actor_id" => 55 } },
             { "draft" => { "description" => "private" } },
             { "clarification_count" => 3 }].each do |invalid|
              assert_equal :invalid, store.write(context: context, state: state.merge(invalid), expected_version: 0)
            end
          end

          def test_each_history_timestamp_is_checked_even_with_fresh_cache_ttl
            turns = [NOW.to_i - 1800, NOW.to_i - 1799, NOW.to_i + 1, nil, "invalid", Float::INFINITY].map do |at|
              { "user" => "Raspored", "bot" => "Koje naselje?", "at" => at }
            end

            result = StateStore.prune_history(turns, now: NOW)
            assert_equal 1, result.size
            assert_equal NOW.to_i - 1799, result.first.fetch("at")
          end

          def test_history_and_state_cannot_resurrect_credential_turns
            secrets = ["123456", "+387 65 123 456", "token: secret-value", "https://example.test/v/abcdefghijk", "Moj kod je 123456", "Код је 123456"]
            secrets.each do |secret|
              assert_empty StateStore.prune_history([{ "user" => secret, "bot" => "U redu", "at" => NOW.to_i }], now: NOW)
            end
            store = StateStore.new(redis: FakeRedis.new)
            state = store.read(context: context).merge("entities" => { "description" => "token: private" })
            assert_equal :invalid, store.write(context: context, state:, expected_version: 0)
          end

          def test_years_dates_category_choices_and_normal_questions_remain_usable
            ["2026", "2026-09-05", "1", "A sutra?", "Kako da promijenim lozinku?", "Како да промијеним лозинку?"].each do |text|
              refute StateStore.sensitive_text?(text)
            end
            assert StateStore.clear_command?("Обриши разговор")
            refute StateStore.clear_command?("Ne objavljuj, promijeni adresu")
          end

          def test_history_never_exceeds_six_user_reply_pairs
            turns = 10.times.map { |index| { "user" => "Pitanje #{index}", "bot" => "Odgovor", "at" => NOW.to_i - index } }

            assert_equal 6, StateStore.prune_history(turns, now: NOW).size
          end

          def test_history_requires_bounded_pairs_and_drops_unknown_payloads
            turn = { "user" => "Pitanje", "bot" => "Odgovor", "at" => NOW.to_i }
            assert_empty StateStore.prune_history([turn.except("bot")], now: NOW)
            assert_empty StateStore.prune_history([turn.merge("bot" => "x" * 2001)], now: NOW)
            refute StateStore.prune_history([turn.merge("private_record" => { "secret" => "value" })], now: NOW).first.has_key?("private_record")
          end

          def test_state_entities_require_matching_provenance
            store = StateStore.new(redis: FakeRedis.new)
            state = store.empty_state(context).merge("entities" => { "area_query" => "Dvorovi" })
            assert_equal :invalid, store.write(context: context, state:, expected_version: 0)
            state["entity_provenance"] = { "area_query" => "citizen" }
            assert_equal :saved, store.write(context: context, state:, expected_version: 0)
          end

          def test_change_area_topic_invariant_applies_to_active_and_suspended_state
            store = StateStore.new(redis: FakeRedis.new)
            empty = store.empty_state(context)
            invalid_active = empty.merge("active_task" => "change_area", "topic" => "neighborhood")
            invalid_suspended = empty.slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "change_area", "topic" => "neighborhood"
            )

            assert_equal :invalid, store.write(context: context, state: invalid_active, expected_version: 0)
            assert_equal :invalid, store.write(
              context: context, state: empty.merge("suspended_task" => invalid_suspended), expected_version: 0
            )
          end

          def test_valid_change_area_state_round_trips_for_active_and_suspended_tasks
            redis = FakeRedis.new
            store = StateStore.new(redis:)
            active = store.empty_state(context).merge("active_task" => "change_area", "topic" => "account")
            suspended = store.empty_state(context).slice(*StateStore::TASK_KEYS).merge(
              "active_task" => "change_area", "topic" => "account"
            )
            state = active.merge("suspended_task" => suspended)

            assert_equal :saved, store.write(context: context, state:, expected_version: 0)
            round_trip = store.read(context: context)
            assert_equal "change_area", round_trip.fetch("active_task")
            assert_equal "account", round_trip.fetch("topic")
            assert_equal "change_area", round_trip.dig("suspended_task", "active_task")
            assert_equal "account", round_trip.dig("suspended_task", "topic")
          end
        end
      end
    end
  end
end

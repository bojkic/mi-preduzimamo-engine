# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"
require "digest"
require "json"
require "securerandom"
require_relative "../../../../../app/services/decidim/bih/durable_effects"

module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      def self.table_name=(*); end

      def self.belongs_to(*); end

      def self.validates(*); end

      def self.scope(*); end
    end
    INBOUND_DELIVERY_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../../app/models/decidim/bih/viber/inbound_delivery"

module Decidim
  remove_const(:ApplicationRecord) if const_defined?(:INBOUND_DELIVERY_TEST_DEFINED_APPLICATION_RECORD, false)
  remove_const(:INBOUND_DELIVERY_TEST_DEFINED_APPLICATION_RECORD) if const_defined?(:INBOUND_DELIVERY_TEST_DEFINED_APPLICATION_RECORD, false)

  module Bih
    module Viber
      class InboundDeliveryContractTest < Minitest::Test
        Message = Struct.new(:message_id, :sender, :channel, keyword_init: true)

        def setup
          @test_application = Struct.new(:secret_key_base).new("inbound-delivery-contract-test-secret")
        end

        def test_viber_keeps_legacy_digest_while_new_channels_are_domain_separated
          raw = "provider-message-1"
          legacy = Digest::SHA256.hexdigest(raw)

          with_crypto do
            assert_equal legacy, digest(raw, channel: "viber")
            refute_equal legacy, digest(raw, channel: "whatsapp")
            refute_equal digest(raw, channel: "whatsapp"), digest(raw, channel: "messenger")
            refute_equal digest(raw, channel: "messenger"), digest(raw, channel: "instagram")
          end
        end

        def test_non_viber_sender_digest_is_keyed_not_plain_sha256
          raw = "38765123456"

          with_crypto do
            refute_equal Digest::SHA256.hexdigest("whatsapp\0#{raw}"), digest(raw, channel: "whatsapp")
            assert_equal digest(raw, channel: "whatsapp"), digest(raw, channel: "whatsapp")
          end
        end

        def test_same_non_viber_redelivery_has_same_channel_key
          message = Message.new(message_id: "provider-message-2", sender: "opaque-user", channel: "whatsapp")

          first = with_crypto { InboundDelivery.send(:provider_message_key, message, channel: "whatsapp") }
          second = with_crypto { InboundDelivery.send(:provider_message_key, message, channel: "whatsapp") }

          assert_equal first, second
          assert_equal 64, first.length
          refute_equal(
            first,
            with_crypto { InboundDelivery.send(:provider_message_key, message, channel: "instagram") }
          )
        end

        def test_missing_provider_message_id_is_rejected_instead_of_randomized
          message = Message.new(message_id: nil, sender: "opaque-user", channel: "viber")

          assert_raises(ArgumentError) do
            InboundDelivery.send(:provider_message_key, message, channel: "viber")
          end
        end

        def test_messages_without_a_channel_keep_viber_compatibility
          legacy_message = Struct.new(:message_id, :sender).new("provider-message-3", "opaque-viber-user")

          assert_equal "viber", InboundDelivery.send(:message_channel, legacy_message)
          assert_equal "messenger", InboundDelivery.send(
            :message_channel,
            Message.new(channel: "messenger")
          )
        end

        def test_sender_order_blocking_states_exclude_processed_terminal_receipts
          assert_equal %w(pending processing failed), InboundDelivery::SENDER_ORDER_BLOCKING_STATES
          refute_includes InboundDelivery::SENDER_ORDER_BLOCKING_STATES, "processed"
          refute_includes InboundDelivery::SENDER_ORDER_BLOCKING_STATES, "discarded"
        end

        def test_recovery_scope_fences_exhausted_handler_failures_but_keeps_effects_recoverable
          source = File.read(File.expand_path("../../../../../app/models/decidim/bih/viber/inbound_delivery.rb", __dir__))

          assert_includes source, '"(state IN (?) AND attempts < ?) OR (state = ? AND updated_at < ?)"'
          assert_includes source, '"(phase = ? AND (#{effects_state})) OR "'
          assert_includes source, '"(phase = ? AND (#{handler_state}))"'
        end

        def test_cursor_advance_tombstones_payload_in_the_same_locked_update
          effects = [
            active_job_effect(1, deadline_at_ms: 2_000),
            active_job_effect(2, deadline_at_ms: 3_000)
          ]
          delivery, state, updates, claims = effect_delivery(effects:, cursor: 0)

          delivery.send(:advance_effect_cursor!, 0, 7)

          assert_equal [[7, "effects"]], claims
          assert_equal 1, updates.size
          assert_equal [:encrypted_effects, :effects_cursor, :next_effect_scrub_at], updates.first.keys
          assert_equal 1, state.fetch(:effects_cursor)
          assert_equal Time.at(3).utc, state.fetch(:next_effect_scrub_at)
          assert_equal Decidim::Bih::DurableEffects.tombstone,
                       state.fetch(:encrypted_effects).fetch(0)
          assert_equal effects.fetch(1), state.fetch(:encrypted_effects).fetch(1)
        end

        def test_expiry_scrub_tombstones_only_due_remaining_slots
          now = Time.utc(2026, 8, 12, 9, 0, 0)
          effects = [
            Decidim::Bih::DurableEffects.tombstone,
            active_job_effect(1, deadline_at_ms: (now.to_f * 1000).to_i),
            active_job_effect(2, deadline_at_ms: ((now + 1.minute).to_f * 1000).to_i),
            active_job_effect(3)
          ]
          delivery, state, updates = effect_delivery(effects:, cursor: 1)

          assert_equal 1, delivery.scrub_expired_effects!(now:)

          scrubbed = state.fetch(:encrypted_effects)
          assert_equal Decidim::Bih::DurableEffects.tombstone, scrubbed.fetch(0)
          assert_equal Decidim::Bih::DurableEffects.tombstone, scrubbed.fetch(1)
          assert_equal effects.fetch(2), scrubbed.fetch(2)
          assert_equal effects.fetch(3), scrubbed.fetch(3)
          assert_equal [{
            encrypted_effects: scrubbed,
            next_effect_scrub_at: now + 1.minute
          }], updates
          assert_equal 1, state.fetch(:effects_cursor)
          assert_equal 4, state.fetch(:effects_count)
          assert_equal 0, delivery.scrub_expired_effects!(now:)
          assert_equal 1, updates.size
        end

        def test_unreadable_effects_are_reverified_then_terminally_discarded
          delivery, state, updates, counters = unreadable_effect_delivery(second_read: :unreadable)

          assert_equal :discarded, delivery.scrub_expired_effects!

          assert_equal 2, counters.fetch(:locks)
          assert_equal 2, counters.fetch(:decrypts)
          assert_equal 1, updates.size
          assert_equal "discarded", state.fetch(:state)
          assert_equal "complete", state.fetch(:phase)
          assert_kind_of Time, state.fetch(:processed_at).to_time # Time or TimeWithZone, never nil
          assert_nil state.fetch(:encrypted_payload)
          assert_nil state.fetch(:encrypted_effects)
          assert_nil state.fetch(:next_effect_scrub_at)
          assert_nil state.fetch(:sender_digest)
          assert_equal "UnreadableEffects", state.fetch(:error_class)
          assert_equal "dedupe-key", state.fetch(:provider_message_key)
          assert_equal 7, state.fetch(:attempts)
          assert_equal 1, state.fetch(:effects_count)
        end

        def test_unreadable_effect_discard_cannot_overwrite_a_newer_claim
          delivery, state, updates, counters = unreadable_effect_delivery(
            second_read: :unreadable,
            advance_generation_on_second_lock: true
          )

          assert_equal :stale, delivery.scrub_expired_effects!

          assert_equal 2, counters.fetch(:locks)
          assert_equal 1, counters.fetch(:decrypts)
          assert_empty updates
          assert_equal 8, state.fetch(:attempts)
          assert_equal "processing", state.fetch(:state)
          assert_equal "effects", state.fetch(:phase)
          assert_equal "private-effects-ciphertext", state.fetch(:encrypted_effects)
        end

        def test_unreadable_effect_discard_preserves_a_concurrently_repaired_envelope
          delivery, state, updates, counters = unreadable_effect_delivery(second_read: :readable)

          assert_equal :readable, delivery.scrub_expired_effects!

          assert_equal 2, counters.fetch(:locks)
          assert_equal 2, counters.fetch(:decrypts)
          assert_empty updates
          assert_equal "processing", state.fetch(:state)
          assert_equal "effects", state.fetch(:phase)
          assert_equal "private-effects-ciphertext", state.fetch(:encrypted_effects)
          assert_nil state.fetch(:error_class)
        end

        def test_every_effects_claim_increments_its_fencing_generation
          delivery = InboundDelivery.new
          attempts = 6
          written_generations = []
          delivery.define_singleton_method(:phase) { "effects" }
          delivery.define_singleton_method(:attempts) { attempts }
          delivery.define_singleton_method(:enqueueable?) { true }
          delivery.define_singleton_method(:with_lock) { |&block| block.call }
          delivery.define_singleton_method(:update!) do |attributes|
            attempts = attributes.fetch(:attempts)
            written_generations << attempts
          end

          assert_equal 7, delivery.send(:claim!)
          assert_equal 8, delivery.send(:claim!)
          assert_equal [7, 8], written_generations
        end

        private

        def digest(value, channel:)
          InboundDelivery.send(:identifier_digest, value, channel:)
        end

        def active_job_effect(id, deadline_at_ms: nil)
          effect = {
            "type" => "active_job",
            "job_class" => "Decidim::Bih::ReportProcessingJob",
            "arguments" => [id]
          }
          effect["deadline_at_ms"] = deadline_at_ms if deadline_at_ms
          effect
        end

        def effect_delivery(effects:, cursor:)
          delivery = InboundDelivery.new
          copy = ->(value) { Marshal.load(Marshal.dump(value)) }
          state = {
            phase: "effects",
            attempts: 7,
            effects_cursor: cursor,
            effects_count: effects.size,
            encrypted_effects: copy.call(effects),
            next_effect_scrub_at: nil
          }
          updates = []
          claims = []

          [:phase, :attempts, :effects_cursor, :effects_count, :encrypted_effects, :next_effect_scrub_at].each do |attribute|
            delivery.define_singleton_method(attribute) { state.fetch(attribute) }
          end
          delivery.define_singleton_method(:with_lock) { |&block| block.call }
          delivery.define_singleton_method(:assert_active_claim!) do |generation, expected_phase: nil|
            claims << [generation, expected_phase]
          end
          delivery.define_singleton_method(:decrypted_effects) { copy.call(state.fetch(:encrypted_effects)) }
          delivery.define_singleton_method(:encrypt_effects) { |value| copy.call(value) }
          delivery.define_singleton_method(:update!) do |attributes|
            copied = copy.call(attributes)
            updates << copied
            state.merge!(copied)
            true
          end

          [delivery, state, updates, claims]
        end

        def unreadable_effect_delivery(second_read:, advance_generation_on_second_lock: false)
          delivery = InboundDelivery.new
          state = {
            state: "processing",
            phase: "effects",
            attempts: 7,
            effects_cursor: 0,
            effects_count: 1,
            encrypted_payload: "private-inbound-ciphertext",
            encrypted_effects: "private-effects-ciphertext",
            next_effect_scrub_at: Time.current,
            sender_digest: "private-sender-digest",
            provider_message_key: "dedupe-key",
            processed_at: nil,
            error_class: nil
          }
          updates = []
          counters = { locks: 0, decrypts: 0 }
          repaired_effect = active_job_effect(1)

          state.each_key do |attribute|
            delivery.define_singleton_method(attribute) { state.fetch(attribute) }
          end
          delivery.define_singleton_method(:with_lock) do |&block|
            counters[:locks] += 1
            state[:attempts] += 1 if advance_generation_on_second_lock && counters[:locks] == 2
            block.call
          end
          delivery.define_singleton_method(:decrypted_effects) do
            counters[:decrypts] += 1
            raise ArgumentError, "private corrupt envelope detail" if
              counters[:decrypts] == 1 || second_read == :unreadable

            [repaired_effect]
          end
          delivery.define_singleton_method(:update!) do |attributes|
            updates << attributes.dup
            state.merge!(attributes)
            true
          end

          [delivery, state, updates, counters]
        end

        def with_crypto(&)
          return Rails.stub(:application, @test_application, &) if Rails.respond_to?(:application)

          installed = true
          Rails.define_singleton_method(:application) { @inbound_delivery_contract_application }
          Rails.instance_variable_set(:@inbound_delivery_contract_application, @test_application)
          yield
        ensure
          if installed
            Rails.singleton_class.send(:remove_method, :application) if Rails.singleton_class.method_defined?(:application)
            Rails.remove_instance_variable(:@inbound_delivery_contract_application) if
              Rails.instance_variable_defined?(:@inbound_delivery_contract_application)
          end
        end
      end
    end
  end
end

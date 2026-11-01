# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/concierge/session_store"

module Decidim
  module Bih
    module Concierge
      class SessionStoreTest < Minitest::Test
        class FakeRedis
          attr_reader :values, :ttls

          def initialize
            @values = {}
            @ttls = {}
          end

          def get(key)
            values[key]
          end

          def set(key, value, ex:) # rubocop:disable Naming/MethodParameterName
            values[key] = value
            ttls[key] = ex
            "OK"
          end

          def del(key)
            ttls.delete(key)
            values.delete(key) ? 1 : 0
          end
        end

        def setup
          @redis = FakeRedis.new
          @store = SessionStore.new(
            redis: @redis,
            organization_id: 42,
            hmac_key: "purpose-isolated-viber-session-test-key"
          )
        end

        def test_redis_key_is_organization_scoped_hmac_and_never_contains_sender
          sender = "private-opaque-viber-user"

          @store.set(sender:, state: "awaiting_phone")

          key = @redis.values.keys.first
          assert_match(/\Abih:viber:state:42:[0-9a-f]{64}\z/, key)
          refute_includes key, sender
          assert_equal SessionStore::DEFAULT_TTL, @redis.ttls.fetch(key)
          assert_equal "awaiting_phone", @store.get(sender:)
        end

        def test_sender_digest_is_domain_and_tenant_separated
          sender = "same-provider-user"
          other_organization = @store.for_organization(43)

          @store.set(sender:, state: "first")
          other_organization.set(sender:, state: "second")

          keys = @redis.values.keys
          assert_equal 2, keys.size
          assert_equal 2, keys.uniq.size
          assert(keys.none? { |key| key.include?(sender) })
        end

        def test_clear_uses_the_same_private_key
          @store.set(sender: "private-user", state: "awaiting_code")

          assert_equal 1, @store.clear(sender: "private-user")
          assert_empty @redis.values
        end

        def test_bounds_state_and_rejects_malformed_sender
          @store.set(sender: "private-user", state: "x" * (SessionStore::MAX_STATE_BYTES + 10))

          assert_equal SessionStore::MAX_STATE_BYTES, @redis.values.values.first.bytesize
          assert_raises(ArgumentError) { @store.set(sender: "", state: "awaiting_phone") }
          assert_raises(ArgumentError) do
            @store.set(sender: "s" * (SessionStore::MAX_SENDER_BYTES + 1), state: "awaiting_phone")
          end
          assert_raises(ArgumentError) { @store.set(sender: "private-user", state: " ") }
        end

        def test_ttl_cannot_outlive_the_ten_minute_privacy_boundary
          @store.set(sender: "private-user", state: "awaiting_phone", ttl: 3600)

          assert_equal SessionStore::DEFAULT_TTL, @redis.ttls.values.first
        end
      end
    end
  end
end

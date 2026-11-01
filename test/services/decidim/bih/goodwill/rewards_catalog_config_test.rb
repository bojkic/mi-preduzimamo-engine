# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"
require "active_support/testing/time_helpers"
require "active_support/time"
require "decidim/bih"
require "i18n"
require_relative "../../../../../app/services/decidim/bih/goodwill/rewards_catalog"

module Decidim
  module Bih
    module Goodwill
      class RewardsCatalogConfigTest < Minitest::Test
        include ActiveSupport::Testing::TimeHelpers

        def setup
          @original_catalog = Decidim::Bih.goodwill_rewards_catalog
          @original_available_locales = I18n.available_locales
          I18n.available_locales = (I18n.available_locales + [:en]).uniq
        end

        def teardown
          Decidim::Bih.goodwill_rewards_catalog = @original_catalog
          I18n.available_locales = @original_available_locales
        end

        def test_config_rewards_filter_blank_keys_and_coerce_values
          Decidim::Bih.goodwill_rewards_catalog = [
            { "key" => "sticker", "cost" => "150", "stock" => "3" },
            { key: "   ", cost: 200 },
            { cost: 300 },
            { key: "badge", cost: nil }
          ]

          rewards = RewardsCatalog.all

          assert_equal %w(sticker badge), rewards.map(&:key)
          assert_equal 150, rewards.first.cost
          assert_equal 3, rewards.first.stock
          assert_equal 0, rewards.last.cost
          assert_nil rewards.last.stock
        end

        def test_config_find_uses_string_keys_and_does_not_require_an_organization
          Decidim::Bih.goodwill_rewards_catalog = [
            { key: :sticker, cost: 150 },
            { key: "bag", cost: 300 }
          ]

          assert_equal "sticker", RewardsCatalog.find(:sticker).key
          assert_equal 300, RewardsCatalog.find("bag").cost
          assert_nil RewardsCatalog.find("missing")
        end

        def test_config_fallback_is_used_for_organization_when_table_is_unavailable
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "fallback", cost: 100 }]

          with_reward_model(table_available: false) do
            assert_equal ["fallback"], RewardsCatalog.all(Object.new).map(&:key)
          end
        end

        def test_database_probe_error_does_not_silently_reopen_legacy_catalog
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "fallback", cost: 100 }]

          with_reward_model(table_error: RuntimeError.new("database unavailable")) do
            assert_raises(RuntimeError) { RewardsCatalog.all(Object.new) }
          end
        end

        def test_table_rewards_take_precedence_when_present
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "fallback", cost: 100 }]
          organization = Object.new
          table_reward = Object.new

          with_reward_model(table_rewards: [table_reward]) do
            assert_same table_reward, RewardsCatalog.all(organization).first
          end
        end

        def test_empty_table_result_falls_back_to_config
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "fallback", cost: 100 }]

          with_reward_model(table_rewards: []) do
            assert_equal ["fallback"], RewardsCatalog.all(Object.new).map(&:key)
          end
        end

        def test_adopted_or_closed_empty_catalog_never_falls_back
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "fallback", cost: 100 }]
          %w(managed closed unexpected).each do |mode|
            with_reward_model(stored_mode: mode) { assert_empty RewardsCatalog.all(Object.new) }
          end
        end

        def test_date_expiry_uses_end_of_day_in_application_timezone
          Decidim::Bih.goodwill_rewards_catalog = [
            { key: "today", cost: 100, expires_at: Date.new(2026, 6, 18) }
          ]

          Time.use_zone("Europe/Sarajevo") do
            rewards = RewardsCatalog.all

            assert_equal Time.zone.parse("2026-06-18").end_of_day, rewards.first.expires_at
          end
        end

        def test_time_expiry_is_kept_precise
          expires_at = Time.utc(2026, 6, 18, 12, 30, 15)
          Decidim::Bih.goodwill_rewards_catalog = [
            { key: "slot", cost: 100, expires_at: }
          ]

          rewards = RewardsCatalog.all

          assert_equal expires_at, rewards.first.expires_at
        end

        def test_i18n_text_uses_reward_key_paths
          I18n.backend.store_translations(
            :en,
            decidim: {
              bih: {
                goodwill: {
                  rewards: { sticker: "Sticker pack" },
                  reward_descriptions: { sticker: "Printed recognition stickers" },
                  reward_fulfillment: { sticker: "Pick up at LFBN office" }
                }
              }
            }
          )
          Decidim::Bih.goodwill_rewards_catalog = [{ key: "sticker", cost: 150 }]

          I18n.with_locale(:en) do
            rewards = RewardsCatalog.all
            reward = rewards.first

            assert_equal "Sticker pack", reward.name
            assert_equal "Printed recognition stickers", reward.description
            assert_equal "Pick up at LFBN office", reward.fulfillment
          end
        end

        def test_reward_expiry_is_false_without_a_deadline_or_at_the_deadline
          Time.use_zone("UTC") do
            deadline = Time.zone.local(2026, 6, 18, 12)

            travel_to(deadline) do
              assert_equal false, RewardsCatalog::Reward.new(key: "open", cost: 100).expired?
              assert_equal false, RewardsCatalog::Reward.new(key: "slot", cost: 100, expires_at: deadline).expired?
            end
          end
        end

        def test_reward_expiry_is_true_after_the_deadline
          Time.use_zone("UTC") do
            deadline = Time.zone.local(2026, 6, 18, 12)

            travel_to(deadline + 1.second) do
              assert RewardsCatalog::Reward.new(key: "slot", cost: 100, expires_at: deadline).expired?
            end
          end
        end

        def test_remaining_stock_is_nil_for_uncapped_rewards
          reward = RewardsCatalog::Reward.new(key: "open", cost: 100, stock: nil)

          assert_nil reward.remaining_stock(Object.new)
        end

        def test_remaining_stock_for_zero_stock_is_zero
          reward = RewardsCatalog::Reward.new(key: "closed", cost: 100, stock: 0)

          with_reward_fulfillment_count(0) do
            assert_equal 0, reward.remaining_stock(Object.new)
          end
        end

        def test_remaining_stock_subtracts_consumed_fulfillments_and_floors_at_zero
          organization = Object.new
          reward = RewardsCatalog::Reward.new(key: "bag", cost: 100, stock: 5)

          with_reward_fulfillment_count(2) do |calls|
            assert_equal 3, reward.remaining_stock(organization)
            assert_equal [[:where, { organization:, reward_key: "bag" }], [:not, { status: %w(canceled reversed) }]], calls
          end

          with_reward_fulfillment_count(7) do
            assert_equal 0, reward.remaining_stock(organization)
          end
        end

        private

        def with_reward_model(table_rewards: [], table_error: nil, table_available: true, stored_mode: nil)
          relation_class = Class.new do
            define_method(:initialize) { |rows| @rows = rows }
            define_method(:active) { self }
            define_method(:ordered) { self }
            define_method(:to_a) { @rows }
            define_method(:exists?) { @rows.any? }
          end
          fake = Class.new do
            define_singleton_method(:table_exists?) do
              raise table_error if table_error

              table_available
            end
            define_singleton_method(:where) { |_conditions| relation_class.new(table_rewards) }
          end

          settings = Class.new do
            define_singleton_method(:where) do |**|
              Object.new.tap { |relation| relation.define_singleton_method(:pick) { |_| stored_mode } }
            end
          end
          namespace = Decidim::Bih
          previous_setting = namespace.const_get(:Setting, false) if namespace.const_defined?(:Setting, false)
          namespace.send(:remove_const, :Setting) if namespace.const_defined?(:Setting, false)
          namespace.const_set(:Setting, settings)
          with_goodwill_constant(:Reward, fake) { yield }
        ensure
          namespace.send(:remove_const, :Setting) if namespace&.const_defined?(:Setting, false)
          namespace.const_set(:Setting, previous_setting) if previous_setting
        end

        def with_reward_fulfillment_count(count)
          calls = []
          relation_class = Class.new do
            define_method(:initialize) do |record_count, relation_calls|
              @count = record_count
              @calls = relation_calls
            end

            define_method(:where) do |conditions = nil|
              return where_chain_class.new(self) if conditions.nil?

              @calls << [:where, conditions]
              self
            end

            define_method(:record_not) do |conditions|
              @calls << [:not, conditions]
              self
            end

            define_method(:count) { @count }
          end
          where_chain_class = Class.new do
            define_method(:initialize) { |relation| @relation = relation }
            define_method(:not) { |conditions| @relation.record_not(conditions) }
          end
          relation_class.define_method(:where_chain_class) { where_chain_class }
          fake = Class.new do
            define_singleton_method(:where) do |conditions|
              relation = relation_class.new(count, calls)
              relation.where(conditions)
            end
          end

          with_goodwill_constant(:RewardFulfillment, fake) { yield calls }
        end

        def with_goodwill_constant(name, value)
          namespace = Decidim::Bih::Goodwill
          previous = namespace.const_get(name, false) if namespace.const_defined?(name, false)
          had_previous = namespace.const_defined?(name, false)
          namespace.send(:remove_const, name) if had_previous
          namespace.const_set(name, value)
          yield
        ensure
          namespace.send(:remove_const, name) if namespace.const_defined?(name, false)
          namespace.const_set(name, previous) if had_previous
        end
      end
    end
  end
end

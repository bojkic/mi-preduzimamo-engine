# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"

module Decidim
  module Bih
    unless const_defined?(:Setting, false)
      class Setting
        class << self
          attr_accessor :store
        end

        self.store = {}

        def self.namespace_for(organization, namespace)
          store.fetch([organization.id, namespace.to_s], {})
        end

        def self.put(organization, namespace, key, value)
          namespace_store = store[[organization.id, namespace.to_s]] ||= {}

          if value.nil? || (value.respond_to?(:blank?) && value.blank? && value != false && value != 0)
            namespace_store.delete(key.to_s)
            return nil
          end

          namespace_store[key.to_s] = value
          value
        end
      end
    end
  end
end

require_relative "../../../../../app/services/decidim/bih/komsiluk/urgent_notification_policy"

module Decidim
  module Bih
    module Komsiluk
      class UrgentNotificationPolicyTest < Minitest::Test
        Organization = Struct.new(:id, keyword_init: true)
        Post = Struct.new(:organization, :category, :komsiluk_id, keyword_init: true)

        def test_missing_settings_preserve_default_urgent_categories
          with_setting_store do
            assert_equal %w(lost_pet safety), UrgentNotificationPolicy.categories_for(organization)
            assert UrgentNotificationPolicy.notify?(build_post("lost_pet"))
            assert UrgentNotificationPolicy.notify?(build_post("safety"))
            assert_equal false, UrgentNotificationPolicy.notify?(build_post("general"))
          end
        end

        def test_save_categories_ignores_unknown_categories
          with_setting_store do
            UrgentNotificationPolicy.new(organization).save_categories(%w(safety general))

            assert_equal ["safety"], UrgentNotificationPolicy.categories_for(organization)
            assert_equal false, UrgentNotificationPolicy.notify?(build_post("lost_pet"))
            assert UrgentNotificationPolicy.notify?(build_post("safety"))
          end
        end

        def test_empty_selection_disables_all_urgent_category_fan_out
          with_setting_store do
            UrgentNotificationPolicy.new(organization).save_categories([])

            assert_equal [], UrgentNotificationPolicy.categories_for(organization)
            assert_equal false, UrgentNotificationPolicy.notify?(build_post("lost_pet"))
            assert_equal false, UrgentNotificationPolicy.notify?(build_post("safety"))
          end
        end

        def test_muted_komsiluk_ids_suppress_only_allowed_selected_areas
          with_setting_store do
            policy = UrgentNotificationPolicy.new(organization)
            policy.save_muted_komsiluk_ids(%w(44 999 bad 44), allowed_ids: [44, 45])

            assert_equal ["44"], UrgentNotificationPolicy.muted_komsiluk_ids_for(organization)
            assert_equal false, UrgentNotificationPolicy.notify?(build_post("safety", komsiluk_id: 44))
            assert UrgentNotificationPolicy.notify?(build_post("safety", komsiluk_id: 45))
          end
        end

        def test_empty_muted_komsiluk_selection_restores_area_fan_out
          with_setting_store do
            policy = UrgentNotificationPolicy.new(organization)
            policy.save_muted_komsiluk_ids([44], allowed_ids: [44])
            policy.save_muted_komsiluk_ids([""], allowed_ids: [44])

            assert_equal [], UrgentNotificationPolicy.muted_komsiluk_ids_for(organization)
            assert UrgentNotificationPolicy.notify?(build_post("safety", komsiluk_id: 44))
          end
        end

        def test_settings_are_scoped_by_organization
          with_setting_store do
            other_organization = Organization.new(id: 200)
            UrgentNotificationPolicy.new(other_organization).save_categories([])
            UrgentNotificationPolicy.new(other_organization).save_muted_komsiluk_ids([44], allowed_ids: [44])

            assert_equal %w(lost_pet safety), UrgentNotificationPolicy.categories_for(organization)
            assert_equal [], UrgentNotificationPolicy.categories_for(other_organization)
            assert_equal [], UrgentNotificationPolicy.muted_komsiluk_ids_for(organization)
            assert_equal ["44"], UrgentNotificationPolicy.muted_komsiluk_ids_for(other_organization)
          end
        end

        private

        def organization
          @organization ||= Organization.new(id: 100)
        end

        def build_post(category, komsiluk_id: 44)
          Post.new(organization:, category:, komsiluk_id:)
        end

        def with_setting_store
          ensure_setting_method(:namespace_for)
          ensure_setting_method(:put)

          store = {}
          namespace_for = lambda do |stored_organization, namespace|
            store.fetch([stored_organization.id, namespace.to_s], {})
          end
          put = lambda do |stored_organization, namespace, key, value|
            namespace_store = store[[stored_organization.id, namespace.to_s]] ||= {}

            if value.nil? || (value.respond_to?(:blank?) && value.blank? && value != false && value != 0)
              namespace_store.delete(key.to_s)
              next nil
            end

            namespace_store[key.to_s] = value
            value
          end

          Decidim::Bih::Setting.stub(:namespace_for, namespace_for) do
            Decidim::Bih::Setting.stub(:put, put) do
              yield
            end
          end
        end

        def ensure_setting_method(method_name)
          return if Decidim::Bih::Setting.respond_to?(method_name)

          Decidim::Bih::Setting.define_singleton_method(method_name) do |*_args|
            nil
          end
        end
      end
    end
  end
end

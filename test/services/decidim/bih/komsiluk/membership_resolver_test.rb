# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/hash/indifferent_access"
require "active_support/core_ext/object/blank"
require_relative "../../../../../app/services/decidim/bih/komsiluk/membership_resolver"

module Decidim
  module Bih
    module Komsiluk
      class MembershipResolverTest < Minitest::Test
        Organization = Struct.new(:id, keyword_init: true)
        UserRecord = Struct.new(:id, :notification_settings, keyword_init: true)

        class ProfileRelation
          attr_reader :calls

          def initialize(user_ids)
            @user_ids = user_ids
            @calls = []
          end

          def where(*args)
            @calls << [:where, args]
            self
          end

          def not(conditions)
            @calls << [:not, conditions]
            @user_ids = @user_ids.reject { |id| conditions[:decidim_user_id].nil? && id.nil? }
            self
          end

          def pluck(column)
            @calls << [:pluck, column]
            @user_ids
          end
        end

        class UserRelation
          attr_reader :calls

          def initialize(users)
            @users = users
            @calls = []
          end

          def where(*args)
            @calls << [:where, args]
            self
          end

          def not(conditions)
            @calls << [:not, conditions]
            @users = @users.reject { |user| conditions.has_key?(:id) && conditions[:id] == user.id }
            self
          end

          def pluck(column)
            @calls << [:pluck, column]
            @users.map(&column)
          end

          def reject(&)
            @calls << [:reject, :opt_outs]
            @users.reject(&)
          end
        end

        class UserModel
          class << self
            attr_reader :calls, :last_relation

            def reset!(users)
              @users = users
              @calls = []
              @last_relation = nil
            end

            def where(*args)
              @calls << [:where, args]
              @last_relation ||= UserRelation.new(@users)
            end
          end
        end

        def setup
          @organization = Organization.new(id: 12)
        end

        def test_empty_profile_ids_return_empty_array_without_loading_users
          profiles = ProfileRelation.new([])
          UserModel.reset!([])

          with_decidim_user(UserModel) do
            result = resolver_for(profiles).recipient_ids

            assert_equal [], result
            assert_empty UserModel.calls
          end
        end

        def test_exclude_user_id_filters_author_from_active_users
          users = [
            UserRecord.new(id: 1, notification_settings: {}),
            UserRecord.new(id: 2, notification_settings: {}),
            UserRecord.new(id: 3, notification_settings: {})
          ]
          UserModel.reset!(users)

          with_decidim_user(UserModel) do
            result = resolver_for(ProfileRelation.new([1, 2, 3])).recipient_ids(exclude_user_id: 2)

            assert_equal [1, 3], result
            assert_includes UserModel.last_relation.calls, [:not, { id: 2 }]
          end
        end

        def test_opt_outs_are_kept_when_not_honored
          users = [
            UserRecord.new(id: 1, notification_settings: { "komsiluk_board" => false }),
            UserRecord.new(id: 2, notification_settings: {})
          ]
          UserModel.reset!(users)

          with_decidim_user(UserModel) do
            result = resolver_for(ProfileRelation.new([1, 2])).recipient_ids(honor_opt_out: false)

            assert_equal [1, 2], result
          end
        end

        def test_retired_board_opt_out_never_excludes_inbox_recipients
          users = [
            UserRecord.new(id: 1, notification_settings: { "komsiluk_board" => false }),
            UserRecord.new(id: 2, notification_settings: { "komsiluk_board" => true }),
            UserRecord.new(id: 3, notification_settings: {})
          ]
          UserModel.reset!(users)

          with_decidim_user(UserModel) do
            result = resolver_for(ProfileRelation.new([1, 2, 3])).recipient_ids(honor_opt_out: true)

            assert_equal [1, 2, 3], result
            refute_includes UserModel.last_relation.calls, [:reject, :opt_outs]
          end
        end

        def test_both_generations_of_bell_opt_out_are_ignored
          users = [
            UserRecord.new(
              id: 1,
              notification_settings: {
                "komsiluk_board" => false,
                "mi_komsiluk_urgent_bell" => true
              }
            ),
            UserRecord.new(
              id: 2,
              notification_settings: {
                "komsiluk_board" => true,
                "mi_komsiluk_urgent_bell" => false
              }
            )
          ]
          UserModel.reset!(users)

          with_decidim_user(UserModel) do
            result = resolver_for(ProfileRelation.new([1, 2])).recipient_ids(honor_opt_out: true)

            assert_equal [1, 2], result
          end
        end

        def test_symbol_legacy_keys_cannot_hide_inbox_notifications
          users = [
            UserRecord.new(id: 1, notification_settings: { komsiluk_board: false }.with_indifferent_access),
            UserRecord.new(id: 2, notification_settings: { komsiluk_board: true }.with_indifferent_access)
          ]
          UserModel.reset!(users)

          with_decidim_user(UserModel) do
            result = resolver_for(ProfileRelation.new([1, 2])).recipient_ids(honor_opt_out: true)

            assert_equal [1, 2], result
          end
        end

        private

        def resolver_for(profiles)
          MembershipResolver.new(organization: @organization, profiles:)
        end

        def with_decidim_user(user_class)
          old_defined = Decidim.const_defined?(:User, false)
          old_value = Decidim.const_get(:User, false) if old_defined
          Decidim.send(:remove_const, :User) if old_defined
          Decidim.const_set(:User, user_class)
          yield
        ensure
          Decidim.send(:remove_const, :User) if Decidim.const_defined?(:User, false)
          Decidim.const_set(:User, old_value) if old_defined
        end
      end
    end
  end
end

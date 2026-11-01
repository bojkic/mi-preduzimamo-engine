# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"

# Decidim::Bih::Goodwill::Account normally inherits from
# Decidim::ApplicationRecord (an ActiveRecord base needing a live DB). To
# exercise its host-free PUBLIC-leaderboard exclusion RULE in isolation we
# provide a minimal stand-in base class that records the class-macro calls the
# model makes at load time, without any database. (The SQL scope itself —
# public_leaderboard_accounts — runs against a live Postgres table and is
# covered by the rails_test integration harness; what is unit-isolable and
# asserted here is the Ruby rule that scope mirrors.)
#
# This base class is defined only if the real constant is absent, and is torn
# down afterwards so it can never leak a too-thin base class into other files.
module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      def self.table_name=(*); end

      def self.belongs_to(*); end

      def self.has_many(*); end

      def self.validates(*); end

      def self.validate(*); end

      def self.scope(*); end
    end
    ACCOUNT_LEADERBOARD_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../../app/models/decidim/bih/goodwill/account"

module Decidim
  if const_defined?(:ACCOUNT_LEADERBOARD_TEST_DEFINED_APPLICATION_RECORD, false)
    remove_const(:ApplicationRecord)
    remove_const(:ACCOUNT_LEADERBOARD_TEST_DEFINED_APPLICATION_RECORD)
  end

  module Bih
    module Goodwill
      # Host-free coverage for the PUBLIC recognition-leaderboard exclusion rule:
      # organization admins, staff/process role holders, and managed accounts are
      # kept OFF the board that the whole organization can see, while ordinary
      # self-registered citizens are eligible to rank. This is the Ruby statement
      # of the rule the public_leaderboard_accounts SQL scope enforces.
      class AccountLeaderboardTest < Minitest::Test
        # Minimal stand-in for a Decidim::User: only the attributes the rule reads.
        FakeUser = Struct.new(:admin, :managed, :roles, :extended_data, :organization,
                              :group, :blocked, :deleted, keyword_init: true) do
          def admin? = admin
          def managed? = managed
          def group? = group
          def blocked? = blocked
          def deleted? = deleted
        end

        class FakeOperatorRoles
          Relation = Struct.new(:exists?)
          class << self
            attr_accessor :active_exists, :lookups

            def active_for(user, organization)
              lookups << [user, organization]
              Relation.new(active_exists)
            end
          end
        end

        def setup
          @organization = Object.new
          @had_operator_role = Decidim::Bih.const_defined?(:OperatorRole, false)
          @previous_operator_role = Decidim::Bih.const_get(:OperatorRole, false) if @had_operator_role
          Decidim::Bih.send(:remove_const, :OperatorRole) if @had_operator_role
          Decidim::Bih.const_set(:OperatorRole, FakeOperatorRoles)
          FakeOperatorRoles.active_exists = false
          FakeOperatorRoles.lookups = []
        end

        def teardown
          Decidim::Bih.send(:remove_const, :OperatorRole)
          Decidim::Bih.const_set(:OperatorRole, @previous_operator_role) if @had_operator_role
        end

        def citizen(**overrides)
          FakeUser.new(admin: false, managed: false, roles: [], extended_data: {},
                       organization: @organization, group: false, blocked: false, deleted: false, **overrides)
        end

        # ---- ordinary citizens still rank --------------------------------- #

        def test_ordinary_citizen_is_not_excluded
          assert_equal false, Account.excluded_from_public_leaderboard?(citizen)
        end

        def test_citizen_with_empty_roles_array_is_not_excluded
          assert_equal false, Account.excluded_from_public_leaderboard?(citizen(roles: []))
        end

        def test_citizen_with_nil_roles_is_not_excluded
          assert_equal false, Account.excluded_from_public_leaderboard?(citizen(roles: nil))
        end

        # ---- admins / staff / managed are excluded ------------------------ #

        def test_organization_admin_is_excluded
          assert_equal true, Account.excluded_from_public_leaderboard?(citizen(admin: true))
        end

        def test_managed_account_is_excluded
          assert_equal true, Account.excluded_from_public_leaderboard?(citizen(managed: true))
        end

        def test_staff_role_holder_is_excluded
          assert_equal true, Account.excluded_from_public_leaderboard?(citizen(roles: ["admin"]))
          assert_equal true, Account.excluded_from_public_leaderboard?(citizen(roles: ["valuator"]))
          assert_equal true, Account.excluded_from_public_leaderboard?(citizen(roles: %w(collaborator moderator)))
        end

        def test_roles_array_with_only_blank_entries_is_not_treated_as_staff
          # A stray empty/nil role string must not exclude a real citizen.
          assert_equal false, Account.excluded_from_public_leaderboard?(citizen(roles: [nil]))
          assert_equal false, Account.excluded_from_public_leaderboard?(citizen(roles: [""]))
        end

        def test_citizen_who_opted_out_of_public_recognition_is_excluded
          assert_equal true,
                       Account.excluded_from_public_leaderboard?(
                         citizen(extended_data: { "bih_public_recognition" => false })
                       )
        end

        def test_nil_user_is_excluded
          assert_equal true, Account.excluded_from_public_leaderboard?(nil)
          assert_empty FakeOperatorRoles.lookups
        end

        def test_group_blocked_and_deleted_accounts_are_excluded
          assert Account.excluded_from_public_leaderboard?(citizen(group: true))
          assert Account.excluded_from_public_leaderboard?(citizen(blocked: true))
          assert Account.excluded_from_public_leaderboard?(citizen(deleted: true))
        end

        def test_active_operator_exclusion_uses_the_users_current_organization
          user = citizen
          FakeOperatorRoles.active_exists = true
          assert Account.excluded_from_public_leaderboard?(user)
          assert_equal [[user, @organization]], FakeOperatorRoles.lookups
        end

        def test_no_active_operator_grant_leaves_an_ordinary_citizen_eligible
          user = citizen
          refute Account.excluded_from_public_leaderboard?(user)
          assert_equal [[user, @organization]], FakeOperatorRoles.lookups
        end

        def test_saved_false_like_preferences_are_respected
          [false, 0, "false", "FALSE", "0", "f", "off", "no"].each do |value|
            assert Account.excluded_from_public_leaderboard?(
              citizen(extended_data: { "bih_public_recognition" => value })
            ), "saved opt-out #{value.inspect} must be respected"
          end
          [nil, true, "true"].each do |value|
            refute Account.excluded_from_public_leaderboard?(
              citizen(extended_data: { "bih_public_recognition" => value })
            )
          end
        end

        # SQL cohort behavior is exercised with persisted users and operator
        # grants in rails_test/goodwill_leaderboard_exclusion_test.rb.
      end
    end
  end
end

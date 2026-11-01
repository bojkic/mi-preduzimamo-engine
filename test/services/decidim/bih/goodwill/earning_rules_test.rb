# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/object/blank"
require "active_support/time"
require "decidim/bih"
require "minitest/mock"
require_relative "../../../../../app/services/decidim/bih/goodwill/earning_rules"

module Decidim
  module Bih
    unless const_defined?(:Setting)
      class Setting
        def self.namespace_for(_organization, _namespace)
          {}
        end
      end
    end

    module Goodwill
      class EarningRulesTest < Minitest::Test
        def setup
          @original_schedule = Decidim::Bih.goodwill_earning_schedule
          @original_caps = Decidim::Bih.goodwill_daily_caps
          @original_season_started_at = Decidim::Bih.goodwill_season_started_at
          @original_work_unit = Decidim::Bih.volunteer_work_award_unit
        end

        def teardown
          Decidim::Bih.goodwill_earning_schedule = @original_schedule
          Decidim::Bih.goodwill_daily_caps = @original_caps
          Decidim::Bih.goodwill_season_started_at = @original_season_started_at
          Decidim::Bih.volunteer_work_award_unit = @original_work_unit
        end

        def test_default_schedule_covers_core_workflow_actions
          with_setting_namespaces({}) do
            rules = rules_for

            assert_equal 100, rules.points_for(:volunteer_hour)
            assert_equal 100, rules.points_for(:volunteer_day)
            assert_equal 10, rules.points_for(:volunteer_availability)
            assert_equal 25, rules.points_for(:volunteer_opportunity)
            assert_equal 15, rules.points_for(:contribution_offer)
            assert_equal 25, rules.points_for(:proposal)
            assert_equal 20, rules.points_for(:report)
            assert_equal 15, rules.points_for(:debate)
            assert_equal 3, rules.points_for(:comment)
            assert_equal 2, rules.points_for(:vote)
            assert_equal 5, rules.points_for(:budget_vote)
            assert_equal 10, rules.points_for(:verification)
            assert_equal 25, rules.points_for(:referral)
            assert_equal 1, rules.points_for(:like)
            assert_equal 10, rules.points_for(:komsiluk_selected)
            assert_equal 40, rules.points_for(:postal_verified)
            assert_equal 10, rules.points_for(:komsiluk_post)
          end
        end

        def test_public_schedule_exposes_only_the_active_work_unit
          with_setting_namespaces({}) do
            rules = rules_for
            Decidim::Bih.volunteer_work_award_unit = :hour
            assert rules.public_schedule.key?(:volunteer_hour)
            refute rules.public_schedule.key?(:volunteer_day)

            Decidim::Bih.volunteer_work_award_unit = :day
            assert rules.public_schedule.key?(:volunteer_day)
            refute rules.public_schedule.key?(:volunteer_hour)
          end
        end

        # Prag kampanje: registracija (verifikacija + komšiluk) = 20 bodova,
        # a 40 se dostiže jednom pravom radnjom ili dvjema malim.
        def test_registration_baseline_and_forty_point_threshold
          with_setting_namespaces({}) do
            rules = rules_for
            registration = rules.points_for(:verification) + rules.points_for(:komsiluk_selected)

            assert_equal 20, registration
            assert_equal 40, registration + rules.points_for(:report)
            assert_equal 45, registration + rules.points_for(:proposal)
            assert_equal 45, registration + rules.points_for(:referral)
            assert_equal 40, registration + (rules.points_for(:komsiluk_post) * 2)
            assert_equal 40, registration + rules.points_for(:debate) +
                             rules.points_for(:comment) + rules.points_for(:vote)
          end
        end

        def test_default_caps_protect_low_effort_actions
          with_setting_namespaces({}) do
            rules = rules_for

            assert_equal 5, rules.cap_for(:comment)
            assert_equal 10, rules.cap_for(:vote)
            assert_equal 20, rules.cap_for(:budget_vote)
            assert_equal 3, rules.cap_for(:debate)
            assert_equal 10, rules.cap_for(:like)
            assert_equal 1, rules.cap_for(:proposal)
            assert_equal :month, rules.cap_period_for(:proposal)
            assert_equal 5, rules.cap_for(:report)
            assert_equal 3, rules.cap_for(:komsiluk_post)
            assert_nil rules.cap_for(:volunteer_hour)
            assert_nil rules.cap_for(:referral)
            assert_nil rules.cap_for(:verification)
            assert_nil rules.cap_for(:contribution_offer)
          end
        end

        def test_daily_caps_bound_cheap_actions_and_keep_farming_guards
          with_setting_namespaces({}) do
            rules = rules_for

            # Nova ograničenja iz specifikacije
            assert_equal 10, rules.cap_for(:like)
            assert_equal 10, rules.cap_for(:vote)
            assert_equal 5, rules.cap_for(:comment)

            # Zadržane zaštite od farmanja bodova
            assert_equal 5, rules.cap_for(:report)
            assert_equal 1, rules.cap_for(:proposal)
            assert_equal :month, rules.cap_period_for(:proposal)
            assert_equal 3, rules.cap_for(:debate)
            assert_equal 3, rules.cap_for(:komsiluk_post)
            assert_equal 20, rules.cap_for(:budget_vote)

            # Radnje koje su nezavisno ograničene (idempotentnost / odobrenje operatora)
            assert_nil rules.cap_for(:volunteer_hour)
            assert_nil rules.cap_for(:referral)
            assert_nil rules.cap_for(:verification)
            assert_nil rules.cap_for(:postal_verified)
            assert_nil rules.cap_for(:komsiluk_selected)
          end
        end

        def test_host_config_overrides_schedule_and_caps_without_dropping_defaults
          Decidim::Bih.goodwill_earning_schedule = { "report" => 30, "custom_action" => 7 }
          Decidim::Bih.goodwill_daily_caps = { "report" => 2, "custom_action" => 1 }

          with_setting_namespaces({}) do
            rules = rules_for

            assert_equal 30, rules.points_for(:report)
            assert_equal 7, rules.points_for(:custom_action)
            assert_equal 100, rules.points_for(:volunteer_hour)
            assert_equal 2, rules.cap_for(:report)
            assert_equal 1, rules.cap_for(:custom_action)
            assert_equal 5, rules.cap_for(:comment)
          end
        end

        def test_organization_settings_override_host_config_when_organization_is_given
          Decidim::Bih.goodwill_earning_schedule = { report: 30, custom_action: 7 }
          Decidim::Bih.goodwill_daily_caps = { report: 4, custom_action: 2 }
          organization = Object.new

          with_setting_namespaces(
            "goodwill_schedule" => { "report" => "45", "custom_action" => "9" },
            "goodwill_caps" => { "report" => "1", "custom_action" => "3" }
          ) do
            rules = rules_for(organization:)

            assert_equal 45, rules.points_for(:report)
            assert_equal 9, rules.points_for(:custom_action)
            assert_equal 1, rules.cap_for(:report)
            assert_equal 3, rules.cap_for(:custom_action)
          end
        end

        def test_blank_organization_settings_are_ignored
          Decidim::Bih.goodwill_earning_schedule = { report: 30 }
          Decidim::Bih.goodwill_daily_caps = { report: 4 }
          organization = Object.new

          with_setting_namespaces(
            "goodwill_schedule" => { "report" => " " },
            "goodwill_caps" => { "report" => "" }
          ) do
            rules = rules_for(organization:)

            assert_equal 30, rules.points_for(:report)
            assert_equal 4, rules.cap_for(:report)
          end
        end

        def test_season_started_at_uses_stored_organization_value_when_parseable
          organization = Object.new

          Time.use_zone("UTC") do
            Decidim::Bih.goodwill_season_started_at = Time.zone.parse("2026-01-01 00:00:00")

            with_setting_namespaces(
              "goodwill_season" => { "started_at" => "2026-02-03 04:05:06" }
            ) do
              assert_equal Time.zone.parse("2026-02-03 04:05:06"), EarningRules.season_started_at(organization)
            end
          end
        end

        def test_season_started_at_falls_back_to_host_config_for_blank_or_bad_values
          organization = Object.new

          Time.use_zone("UTC") do
            config_value = Time.zone.parse("2026-01-01 00:00:00")
            Decidim::Bih.goodwill_season_started_at = config_value

            with_setting_namespaces("goodwill_season" => { "started_at" => "" }) do
              assert_equal config_value, EarningRules.season_started_at(organization)
            end

            with_setting_namespaces("goodwill_season" => { "started_at" => "not-a-date" }) do
              assert_equal config_value, EarningRules.season_started_at(organization)
            end
          end
        end

        private

        def rules_for(organization: nil)
          EarningRules.new(ledger: Object.new, organization:)
        end

        def with_setting_namespaces(namespaces)
          namespace_for = lambda do |_organization, namespace|
            namespaces.fetch(namespace.to_s, {})
          end

          Decidim::Bih::Setting.stub(:namespace_for, namespace_for) { yield }
        end
      end
    end
  end
end

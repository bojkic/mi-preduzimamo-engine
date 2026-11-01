# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/date/calculations"
require "active_support/testing/time_helpers"
require "active_support/time"
require_relative "../../../../../app/services/decidim/bih/goodwill/streaks"

module Decidim
  module Bih
    module Goodwill
      class StreaksWeeklyTest < Minitest::Test
        include ActiveSupport::Testing::TimeHelpers

        Account = Struct.new(:id)

        def test_nil_account_has_no_weekly_streak
          assert_equal 0, Streaks.weekly_for(nil)
        end

        def test_empty_earn_history_has_no_weekly_streak
          with_current_week do
            with_earn_weeks([]) do
              assert_equal 0, Streaks.weekly_for(Account.new(1))
            end
          end
        end

        def test_current_week_anchors_the_streak
          with_current_week do |this_week|
            with_earn_weeks([this_week, this_week - 7, this_week - 14]) do
              assert_equal 3, Streaks.weekly_for(Account.new(1))
            end
          end
        end

        def test_last_week_keeps_the_streak_alive_mid_week
          with_current_week do |this_week|
            with_earn_weeks([this_week - 7, this_week - 14]) do
              assert_equal 2, Streaks.weekly_for(Account.new(1))
            end
          end
        end

        def test_gap_breaks_the_trailing_streak
          with_current_week do |this_week|
            with_earn_weeks([this_week, this_week - 7, this_week - 21]) do
              assert_equal 2, Streaks.weekly_for(Account.new(1))
            end
          end
        end

        def test_old_earn_without_recent_activity_is_not_current
          with_current_week do |this_week|
            with_earn_weeks([this_week - 28]) do
              assert_equal 0, Streaks.weekly_for(Account.new(1))
            end
          end
        end

        private

        def with_current_week
          Time.use_zone("UTC") do
            travel_to(Time.zone.local(2026, 6, 18, 12)) do
              yield Date.current.beginning_of_week
            end
          end
        end

        def with_earn_weeks(weeks)
          Streaks.stub(:earn_week_starts, weeks) { yield }
        end
      end
    end
  end
end

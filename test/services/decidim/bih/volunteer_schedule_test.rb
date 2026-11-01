# frozen_string_literal: true

require "test_helper"
require "securerandom"
require "active_support/core_ext/object/blank"
require_relative "../../../../app/services/decidim/bih/volunteer_schedule"
require_relative "../../../../app/services/decidim/bih/volunteer_signup_window"

module Decidim
  module Bih
    class VolunteerScheduleTest < Minitest::Test
      def test_parses_sarajevo_local_time_and_shifts_every_deadline_weekly
        instances = VolunteerSchedule.new(
          starts_at: "2026-07-20T18:00",
          ends_at: "2026-07-20T20:00",
          signup_deadline_at: "2026-07-19T18:00",
          recurrence_count: 3,
          maximum: 8
        ).instances

        assert_equal 3, instances.size
        assert_equal "Europe/Sarajevo", instances.first.fetch(:starts_at).time_zone.name
        assert_equal 1.week.to_i, instances[1].fetch(:starts_at) - instances.first.fetch(:starts_at)
        assert_equal 1.week.to_i, instances[1].fetch(:signup_deadline_at) - instances.first.fetch(:signup_deadline_at)
        assert_equal [1, 2, 3], (instances.map { |item| item.fetch(:series_position) })
        assert_equal [3], instances.map { |item| item.fetch(:series_total) }.uniq
        assert_equal 1, instances.map { |item| item.fetch(:series_key) }.uniq.size
      end

      def test_recurrence_is_capped_and_requires_a_start
        capped = VolunteerSchedule.new(
          starts_at: "2026-07-20T18:00", ends_at: nil, signup_deadline_at: nil,
          recurrence_count: 99, maximum: 8
        ).instances
        without_start = VolunteerSchedule.new(
          starts_at: nil, ends_at: nil, signup_deadline_at: nil,
          recurrence_count: 4, maximum: 8
        ).instances

        assert_equal 8, capped.size
        assert_equal 1, without_start.size
        assert_equal({}, without_start.first)
      end

      def test_weekly_recurrence_keeps_sarajevo_wall_clock_across_dst_change
        instances = VolunteerSchedule.new(
          starts_at: "2026-10-20T18:00",
          ends_at: "2026-10-20T20:00",
          signup_deadline_at: "2026-10-19T18:00",
          recurrence_count: 2,
          maximum: 8
        ).instances

        assert_equal %w(18:00 18:00), (instances.map { |item| item.fetch(:starts_at).strftime("%H:%M") })
        assert_equal [7200, 3600], (instances.map { |item| item.fetch(:starts_at).utc_offset })
      end

      def test_signup_window_closes_at_the_deadline
        deadline = Time.utc(2026, 7, 20, 12)

        assert VolunteerSignupWindow.open?(deadline:, cancelled: false, at: deadline - 1.second)
        refute VolunteerSignupWindow.open?(deadline:, cancelled: false, at: deadline)
        refute VolunteerSignupWindow.open?(deadline: nil, cancelled: true, at: deadline)
        refute VolunteerSignupWindow.open?(deadline: nil, cancelled: false, paused: true, at: deadline)
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/time_text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class TimeTextTest < Minitest::Test
          NOW = Time.new(2026, 9, 12, 21, 0, 0, "+02:00")

          def render(value, locale: "sr")
            TimeText.call(value, locale:, now: NOW)
          end

          def test_today_and_yesterday_are_named_in_the_sarajevo_zone
            assert_equal "danas u 04:00", render(Time.new(2026, 9, 12, 4, 0, 0, "+02:00"))
            assert_equal "danas u 04:00", render("2026-09-12T02:00:00Z"), "UTC input is shown in Europe/Sarajevo"
            assert_equal "juče u 19:49", render("2026-09-11T19:49:00+02:00")
            assert_equal "jučer u 19:49", render("2026-09-11T19:49:00+02:00", locale: "bs")
            assert_equal "jučer u 19:49", render("2026-09-11T19:49:00+02:00", locale: "hr")
            assert_equal "данас у 04:00", render("2026-09-12T04:00:00+02:00", locale: "sr-Cyrl")
            assert_equal "today at 04:00", render("2026-09-12T04:00:00+02:00", locale: "en")
            assert_equal "yesterday at 19:49", render("2026-09-11T19:49:00+02:00", locale: "en")
          end

          def test_other_days_render_as_a_human_date_and_time
            assert_equal "10.9.2026. u 06:10", render("2026-09-10T06:10:00+02:00")
            assert_equal "1.9.2026. u 10:00", render("2026-09-01T08:00:00Z")
            assert_equal "10.9.2026. у 06:10", render("2026-09-10T06:10:00+02:00", locale: "sr-Cyrl")
            assert_equal "10 Sep 2026, 06:10", render("2026-09-10T06:10:00+02:00", locale: "en")
            assert_equal "10.9.2026. u 06:10", render(Time.utc(2026, 9, 10, 4, 10))
          end

          def test_dates_and_local_midnights_render_as_a_date_only
            assert_equal "9.9.2026.", render("2026-09-09")
            assert_equal "9.9.2026.", render(Date.new(2026, 9, 9))
            assert_equal "29.6.2026.", render(Time.iso8601("2026-06-29T00:00:00+02:00"))
            assert_equal "9.9.2026.", render("2026-09-09", locale: "sr-Cyrl")
            assert_equal "9 Sep 2026", render("2026-09-09", locale: "en")
            assert_equal "danas", render("2026-09-12")
            assert_equal "juče", render(Date.new(2026, 9, 11))
          end

          def test_unparseable_input_is_returned_unchanged
            ["dvorovi", "2026-09-08T00:00:00Z; 2026-09-08T23:59:59Z", "", "not a date", "2026-13-45"].each do |value|
              assert_equal value, render(value), value.inspect
            end
            assert_nil render(nil)
            assert_equal "42", render(42)
            assert_equal "10.9.2026. u 06:10", render("2026-09-10T06:10:00+02:00", locale: "xx"), "unknown locale falls back to sr"
          end
        end
      end
    end
  end
end

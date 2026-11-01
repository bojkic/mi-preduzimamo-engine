# frozen_string_literal: true

require "test_helper"
require "active_support/time"
require "decidim/bih"
require_relative "../../../../../app/services/decidim/bih/race/config"

module Decidim
  module Bih
    module Race
      class ConfigTest < Minitest::Test
        def setup
          @original = [Decidim::Bih.race_window_from, Decidim::Bih.race_window_to,
                       Decidim::Bih.race_weights, Decidim::Bih.race_caps]
        end

        def teardown
          Decidim::Bih.race_window_from, Decidim::Bih.race_window_to,
            Decidim::Bih.race_weights, Decidim::Bih.race_caps = *@original
        end

        def config = Config.new

        def test_window_defaults_to_the_campaign_dates_in_sarajevo_time
          assert_equal "2026-09-06 00:00:00 +0200", config.window_from.strftime("%Y-%m-%d %H:%M:%S %z")
          assert_equal "2026-10-14 20:00:00 +0200", config.window_to.strftime("%Y-%m-%d %H:%M:%S %z")
        end

        def test_default_weights_and_caps_match_the_published_rules
          assert_equal({ registered: 1, report: 2, proposal: 3 }, config.weights)
          assert_equal({ report: 5, proposal: 3 }, config.caps)
        end

        def test_host_config_overrides_the_window
          Decidim::Bih.race_window_from = "2026-09-01 00:00:00"

          assert_equal "2026-09-01 00:00:00 +0200", Config.new.window_from.strftime("%Y-%m-%d %H:%M:%S %z")
        end

        def test_open_and_finished_track_the_window_edges
          subject = config

          zone = ActiveSupport::TimeZone["Europe/Sarajevo"]
          refute subject.open?(zone.parse("2026-09-05 23:59:59"))
          assert subject.open?(zone.parse("2026-09-06 00:00:00"))
          assert subject.open?(zone.parse("2026-10-14 19:59:59"))
          refute subject.open?(zone.parse("2026-10-14 20:00:00")), "the window is half-open: 20:00 is out"
          assert subject.finished?(zone.parse("2026-10-14 20:00:00"))
        end

        def test_nil_weight_value_leaves_the_default_in_place
          Decidim::Bih.race_weights = { report: nil }

          assert_equal 2, config.weights[:report], "nil value should fall through to default"
          assert_equal 1, config.weights[:registered], "other keys untouched"
          assert_equal 3, config.weights[:proposal], "other keys untouched"
        end

        def test_empty_string_weight_value_leaves_the_default_in_place
          Decidim::Bih.race_weights = { report: "" }

          assert_equal 2, config.weights[:report], "empty string should fall through to default"
          assert_equal 1, config.weights[:registered], "other keys untouched"
          assert_equal 3, config.weights[:proposal], "other keys untouched"
        end

        def test_non_numeric_weight_value_is_rejected
          Decidim::Bih.race_weights = { report: "abc" }

          assert_raises(ArgumentError) { config.weights }
        end

        def test_string_integer_weight_value_is_applied
          Decidim::Bih.race_weights = { report: "5" }

          assert_equal 5, config.weights[:report], "string integer should be coerced and applied"
          assert_equal 1, config.weights[:registered], "other keys untouched"
          assert_equal 3, config.weights[:proposal], "other keys untouched"
        end

        def test_partial_weight_override_leaves_other_keys_at_defaults
          Decidim::Bih.race_weights = { proposal: 10 }

          assert_equal 2, config.weights[:report], "overridden key still at default"
          assert_equal 1, config.weights[:registered], "unspecified key at default"
          assert_equal 10, config.weights[:proposal], "overridden key applied"
        end

        def test_nil_cap_value_leaves_the_default_in_place
          Decidim::Bih.race_caps = { report: nil }

          assert_equal 5, config.caps[:report], "nil value should fall through to default"
          assert_equal 3, config.caps[:proposal], "other keys untouched"
        end

        def test_empty_string_cap_value_leaves_the_default_in_place
          Decidim::Bih.race_caps = { report: "" }

          assert_equal 5, config.caps[:report], "empty string should fall through to default"
          assert_equal 3, config.caps[:proposal], "other keys untouched"
        end

        def test_non_numeric_cap_value_is_rejected
          Decidim::Bih.race_caps = { report: "abc" }

          assert_raises(ArgumentError) { config.caps }
        end

        def test_string_integer_cap_value_is_applied
          Decidim::Bih.race_caps = { report: "10" }

          assert_equal 10, config.caps[:report], "string integer should be coerced and applied"
          assert_equal 3, config.caps[:proposal], "other keys untouched"
        end

        def test_partial_cap_override_leaves_other_keys_at_defaults
          Decidim::Bih.race_caps = { proposal: 1 }

          assert_equal 5, config.caps[:report], "unspecified key at default"
          assert_equal 1, config.caps[:proposal], "overridden key applied"
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/geo/zone_modes"

module Decidim
  module Bih
    module Geo
      class ZoneModesTest < Minitest::Test
        def test_apply_mode_is_write
          assert Decidim::Bih::Geo::ZoneModes.write?("apply")
        end

        def test_force_mode_is_write
          assert Decidim::Bih::Geo::ZoneModes.write?("force")
        end

        def test_nil_mode_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?(nil)
        end

        def test_empty_string_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?("")
        end

        def test_misspelled_apply_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?("aply")
        end

        def test_uppercase_apply_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?("APPLY")
        end

        def test_mixed_case_apply_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?("Apply")
        end

        def test_apply_with_leading_space_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?(" apply")
        end

        def test_apply_with_trailing_space_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?("apply ")
        end

        def test_misspelled_force_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?("forc")
        end

        def test_symbol_apply_is_not_write
          refute Decidim::Bih::Geo::ZoneModes.write?(:apply)
        end

        def test_only_force_mode_is_force
          assert Decidim::Bih::Geo::ZoneModes.force?("force")
        end

        def test_apply_mode_is_not_force
          refute Decidim::Bih::Geo::ZoneModes.force?("apply")
        end

        def test_nil_is_not_force
          refute Decidim::Bih::Geo::ZoneModes.force?(nil)
        end

        def test_empty_string_is_not_force
          refute Decidim::Bih::Geo::ZoneModes.force?("")
        end

        def test_uppercase_force_is_not_force
          refute Decidim::Bih::Geo::ZoneModes.force?("FORCE")
        end

        def test_symbol_force_is_not_force
          refute Decidim::Bih::Geo::ZoneModes.force?(:force)
        end
      end
    end
  end
end

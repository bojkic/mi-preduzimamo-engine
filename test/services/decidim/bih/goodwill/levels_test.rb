# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/goodwill/levels"

module Decidim
  module Bih
    module Goodwill
      class LevelsTest < Minitest::Test
        def test_resolves_level_by_threshold
          assert_equal "komsija", Levels.for(0).key
          assert_equal "komsija", Levels.for(49).key
          assert_equal "aktivista", Levels.for(50).key
          assert_equal "heroj", Levels.for(1_500).key
        end

        def test_reports_progress_to_next_level
          level = Levels.for(125)

          assert_equal "aktivista", level.key
          assert_equal 75, level.points_to_next
          assert_equal 50, level.progress_percent
        end

        def test_top_level_has_complete_progress
          level = Levels.for(2_000)

          assert_equal "heroj", level.key
          assert_nil level.points_to_next
          assert_equal 100, level.progress_percent
        end
      end
    end
  end
end

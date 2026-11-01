# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/time"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"
require_relative "../../../../app/services/decidim/bih/admin/volunteer_opportunity_management"

module Decidim
  module Bih
    class VolunteerOpportunityManagementTest < Minitest::Test
      def manager
        Admin::VolunteerOpportunityManagement.new(
          organization: Object.new, opportunity: Object.new, actor: Object.new,
          action: "postpone", scope: "term", attributes: { shift_days: 7 }
        )
      end

      def test_postponement_keeps_local_wall_clock_time_across_autumn_clock_change
        original = Time.utc(2026, 10, 18, 18, 23)
        shifted = manager.send(:shifted, original, 7)

        assert_equal Time.utc(2026, 10, 25, 19, 23), shifted.utc
        assert_equal "20:23", shifted.strftime("%H:%M")
        assert_equal "Europe/Sarajevo", shifted.time_zone.name
      end

      def test_postponement_keeps_local_wall_clock_time_across_spring_clock_change
        original = Time.utc(2027, 3, 21, 19, 23)
        shifted = manager.send(:shifted, original, 7)

        assert_equal Time.utc(2027, 3, 28, 18, 23), shifted.utc
        assert_equal "20:23", shifted.strftime("%H:%M")
      end
    end
  end
end

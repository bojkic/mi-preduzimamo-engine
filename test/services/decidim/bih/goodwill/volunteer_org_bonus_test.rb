# frozen_string_literal: true

require "test_helper"
require "bigdecimal"
require_relative "../../../../../app/services/decidim/bih/goodwill/volunteer_org_bonus"

module Decidim
  module Bih
    module Goodwill
      class VolunteerOrgBonusTest < Minitest::Test
        Opportunity = Struct.new(:org_bonus_points_per_hour, :org_bonus_remaining_points, keyword_init: true)
        Claim = Struct.new(:opportunity, :hours, keyword_init: true)

        def test_fractional_actual_hours_keep_hourly_bonus_separate_from_daily_base
          offer = Opportunity.new(org_bonus_points_per_hour: 50, org_bonus_remaining_points: 1_000)
          bonus = VolunteerOrgBonus.new(Claim.new(opportunity: offer, hours: BigDecimal("1.5")))

          assert_equal 75, bonus.send(:requested_amount)
          assert_equal 75, bonus.send(:capped_amount)
        end

        def test_per_term_budget_caps_fractional_hours_bonus
          offer = Opportunity.new(org_bonus_points_per_hour: 50, org_bonus_remaining_points: 20)
          bonus = VolunteerOrgBonus.new(Claim.new(opportunity: offer, hours: BigDecimal("2")))

          assert_equal 100, bonus.send(:requested_amount)
          assert_equal 20, bonus.send(:capped_amount)
        end
      end
    end
  end
end

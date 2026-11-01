# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Test 13 from the spec: the 600.000 KM claim must be gone from the site.
      # It was never stored as text — it was SUMMED from a published demo budget
      # component holding five invented projects.
      class HeroStatsCampaignTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          Rails.cache.clear
        end

        teardown { Rails.cache.clear }

        test "the hero strip advertises the campaign amount, not a budget total" do
          keys = Decidim::Bih::MiHeroStats.for(@organization).map { |stat| stat[:key] }

          refute_includes keys, "budget", "the budget tile is what rendered 600.000 KM"
          assert_includes keys, "campaign"
        end

        test "the campaign tile states the verifiable 6.000 KM figure" do
          campaign = Decidim::Bih::MiHeroStats.for(@organization).find { |stat| stat[:key] == "campaign" }

          assert_equal "6.000 KM", campaign[:value]
        end

        test "no hero stat renders the 600.000 figure" do
          values = Decidim::Bih::MiHeroStats.for(@organization).map { |stat| stat[:value].to_s }

          assert_empty values.grep(/600[._]?000/)
        end
      end
    end
  end
end

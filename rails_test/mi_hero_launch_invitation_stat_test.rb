# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Zadatak 13 traži brojač i na naslovnoj i na stranici nagrada. Ovo je
      # naslovna polovina — MiHeroCell#stats. `enabled?` je bitna brana: kad
      # istekne talas, ne smije ostati "0 preostalih" zauvijek na naslovnoj.
      class MiHeroLaunchInvitationStatTest < ActionDispatch::IntegrationTest
        Service = Decidim::Bih::Goodwill::LaunchInvitation

        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          host! @organization.host
          FactoryBot.create(:content_block, organization: @organization, scope_name: :homepage,
                                            manifest_name: :mi_hero, published_at: Time.current)
        end

        test "the homepage shows the launch invitation counter while the wave is live" do
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20, stock: 2, deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
          Rails.cache.clear

          get "/"

          assert_response :success
          assert_includes response.body, "preostale pozivnice za lansiranje"
        end

        test "the homepage counter disappears once the wave has expired" do
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 40, stock: 2, deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: 1.day.ago
          )
          Rails.cache.clear

          get "/"

          assert_response :success
          refute_includes response.body, "preostale pozivnice za lansiranje"
          refute_includes response.body, "preostalih pozivnica za lansiranje"
        end
      end
    end
  end
end

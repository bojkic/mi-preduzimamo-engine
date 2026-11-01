# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class LaunchInvitationCounterTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        Service = Decidim::Bih::Goodwill::LaunchInvitation

        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          host! @organization.host
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20, stock: 2, deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
          Rails.cache.clear
        end

        # Mount path derived, ne hardkodovan — test harness montira engine na
        # /moja-platforma, produkcija na /biceriseno.
        def nagrade_path
          "#{Decidim::Bih.public_path("zajednistvo")}?tab=nagrade"
        end

        test "the rewards tab shows the remaining count in the current wave" do
          get nagrade_path

          assert_response :success
          # Nije samo labava podniska — vezano je za stvarnu izračunatu
          # vrijednost koju kontroler prosljeđuje pogledu.
          assert_equal 2, @controller.instance_variable_get(:@launch_invitations_remaining)
          assert_includes response.body, "2"
        end

        test "the counter reaches zero when the wave is exhausted" do
          2.times do |i|
            citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
            Decidim::Bih::Goodwill::Ledger.new.award(citizen, 50, reason: "seed_#{i}")
            Service.issue_for(citizen)
          end
          Rails.cache.clear

          assert_equal 0, Service.remaining(@organization)
        end

        test "the counter never exposes who holds an invitation" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                         name: "Tajni Komsija")
          Decidim::Bih::Goodwill::Ledger.new.award(citizen, 50, reason: "seed")
          invitation = Service.issue_for(citizen)
          Rails.cache.clear

          get nagrade_path

          refute_includes response.body, "Tajni Komsija"
          refute_includes response.body, invitation.entry_code
        end

        test "the invitation holder sees their own code and QR, nobody else does" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.award(citizen, 50, reason: "seed")
          invitation = Service.issue_for(citizen)
          Rails.cache.clear

          sign_in citizen
          get nagrade_path
          assert_includes response.body, invitation.entry_code
          assert_includes response.body, "<svg"
          # Next to the code: it is shown at the door, never typed in anywhere.
          assert_includes response.body,
                          ERB::Util.html_escape(I18n.t("decidim.bih.goodwill.launch_invitation.entry_note", locale: :sr))
          sign_out citizen

          stranger = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in stranger
          get nagrade_path
          refute_includes response.body, invitation.entry_code
        end

        test "manually redeeming the launch invitation reward is refused and leaves the balance untouched" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.award(citizen, 50, reason: "seed")
          balance_before = Decidim::Bih::Goodwill::Ledger.new.account_for(citizen).reload.balance

          sign_in citizen
          assert_no_difference "Decidim::Bih::Goodwill::RewardFulfillment.count" do
            post redeem_path(Service::REWARD_KEY), params: redemption_params
          end

          assert_equal balance_before,
                       Decidim::Bih::Goodwill::Ledger.new.account_for(citizen).reload.balance
        end

        test "the auto-issue reward never appears in the manually-redeemable rewards grid" do
          get nagrade_path

          assert_response :success
          refute_includes response.body, redeem_path(Service::REWARD_KEY)
        end

        test "the auto-issue reward never appears in the kako spend explainer either" do
          get "#{Decidim::Bih.public_path("zajednistvo")}?tab=kako"

          assert_response :success
          refute_includes response.body, "Pozivnica za lansiranje 17.9."
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The link in the invitation SMS/Viber/e-mail confirms attendance by
      # itself — no login. It rides the /v/:token magic-link route with the
      # "invitation" purpose and must never open a session.
      class LaunchInvitationLinkTest < ActionDispatch::IntegrationTest
        Service = Decidim::Bih::Goodwill::LaunchInvitation

        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20, stock: 5, deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
          Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 50, reason: "test_seed")
          @invitation = Service.issue_for(@citizen)
          @url = Service.confirm_link_url(@invitation)
          @path = URI.parse(@url).path
        end

        test "GET shows the tap page without confirming; POST confirms; no session is opened" do
          get @path
          assert_response :success
          assert_nil @invitation.reload.attendance_confirmed_at, "a preview fetch must not confirm"
          assert_includes response.body, "Potvrđujem dolazak"

          post @path
          assert_response :success
          assert @invitation.reload.attendance_confirmed_at.present?
          assert_includes response.body, @invitation.entry_code
          assert_includes response.body, I18n.t("decidim.bih.magic_links.invitation_result.confirmed", locale: :sr)

          get Decidim::Bih.public_path("moj-nalog")
          assert_response :redirect, "the invitation link must never sign the citizen in"
        end

        test "a second tap says already confirmed instead of link invalid" do
          post @path
          post @path
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.magic_links.invitation_result.already_confirmed", locale: :sr)

          get @path
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.magic_links.invitation_result.already_confirmed", locale: :sr)
        end

        test "a missed deadline is explained and confirms nothing" do
          @invitation.update!(confirmation_deadline_at: 1.minute.ago)
          post @path

          assert_response :success
          assert_nil @invitation.reload.attendance_confirmed_at
          assert_includes response.body, I18n.t("decidim.bih.magic_links.invitation_result.deadline_passed", locale: :sr)
        end

        test "an unknown or expired token is the generic invalid page" do
          post Decidim::Bih.magic_link_path("x" * 32)
          assert_response :unprocessable_entity

          travel_to 73.hours.from_now do
            post @path
            assert_response :unprocessable_entity
          end
          assert_nil @invitation.reload.attendance_confirmed_at
        end

        test "an invitation token cannot be spent as a login or verify credential" do
          raw = @path.split("/").last
          assert_nil Decidim::Bih::LoginToken.peek(raw:, organization: @organization, purpose: "login")
          assert_nil Decidim::Bih::LoginToken.peek(raw:, organization: @organization, purpose: "verify")
        end
      end
    end
  end
end

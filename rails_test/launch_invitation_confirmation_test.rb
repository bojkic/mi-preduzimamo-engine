# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class LaunchInvitationConfirmationTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        Service = Decidim::Bih::Goodwill::LaunchInvitation

        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20, stock: 1, deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
          Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 50, reason: "test_seed")
          @invitation = Service.issue_for(@citizen)
        end

        test "a citizen confirms attendance with one click" do
          sign_in @citizen
          post Decidim::Bih.public_path("pozivnica/potvrdi")

          assert_response :redirect
          assert @invitation.reload.attendance_confirmed_at.present?
        end

        test "an unconfirmed invitation is voided after 72 hours and returns to stock" do
          assert_equal 0, Service.remaining(@organization)

          travel_to @invitation.confirmation_deadline_at + 1.minute do
            Decidim::Bih::Goodwill::ExpireLaunchInvitationsJob.perform_now
          end

          assert_equal "canceled", @invitation.reload.status
          assert_equal 1, Service.remaining(@organization),
                       "poništena pozivnica se vraća u zalihu"
        end

        test "a confirmed invitation survives the 72 hour sweep" do
          @invitation.update!(attendance_confirmed_at: Time.current)

          travel_to @invitation.confirmation_deadline_at + 1.minute do
            Decidim::Bih::Goodwill::ExpireLaunchInvitationsJob.perform_now
          end

          assert_equal "reserved", @invitation.reload.status
        end

        test "confirming does not deduct any points" do
          balance_before = Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen).reload.balance

          sign_in @citizen
          post Decidim::Bih.public_path("pozivnica/potvrdi")

          assert_equal balance_before,
                       Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen).reload.balance
        end

        test "an anonymous visitor is redirected somewhere reachable by GET, not a routing error" do
          post Decidim::Bih.public_path("pozivnica/potvrdi")

          assert_response :redirect
          follow_redirect!
          assert_response :success,
                          "redirect target must be a real GET-reachable page, not a routing error"

          assert_nil @invitation.reload.attendance_confirmed_at,
                     "an anonymous POST must not confirm anyone's invitation"
        end

        test "confirming after the sweep already canceled it explains the deadline, not a generic message" do
          sign_in @citizen

          travel_to @invitation.confirmation_deadline_at + 1.minute do
            Decidim::Bih::Goodwill::ExpireLaunchInvitationsJob.perform_now
            assert_equal "canceled", @invitation.reload.status

            post Decidim::Bih.public_path("pozivnica/potvrdi")
          end

          assert_response :redirect
          assert_equal I18n.t(
            "decidim.bih.launch_invitations.confirm.deadline_passed",
            locale: @organization.default_locale
          ), flash[:alert]
        end

        test "a citizen can only ever confirm their own invitation" do
          # Same reward_key as @invitation, issued to a DIFFERENT citizen —
          # the exact row shape someone could try to reach with a manipulated
          # lookup parameter, if one ever existed. Today the controller finds
          # the fulfillment by [organization, current_user, reward_key], so
          # there is no parameter to manipulate; this test pins that so a
          # future lookup-by-id/token change cannot quietly cross the wire.
          other_citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          other_invitation = Decidim::Bih::Goodwill::RewardFulfillment.create!(
            organization: @organization, user: other_citizen,
            reward_key: Service::REWARD_KEY, cost: @reward.cost,
            status: "reserved", auto_issued: true,
            entry_code: Service.generate_entry_code,
            issued_at: Time.current, confirmation_deadline_at: 72.hours.from_now
          )

          sign_in @citizen
          post Decidim::Bih.public_path("pozivnica/potvrdi")

          assert @invitation.reload.attendance_confirmed_at.present?,
                 "the signed-in citizen's own invitation is confirmed"
          assert_nil other_invitation.reload.attendance_confirmed_at,
                     "another citizen's invitation must never be touched"
        end
      end
    end
  end
end

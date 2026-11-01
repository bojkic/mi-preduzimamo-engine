# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class LaunchInvitationCheckinTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        Service = Decidim::Bih::Goodwill::LaunchInvitation

        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @operator = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20, stock: 450, deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
          Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 50, reason: "test_seed")
          @invitation = Service.issue_for(@citizen)
          @invitation.update!(attendance_confirmed_at: Time.current)
        end

        def issue_invitation_for(citizen)
          Decidim::Bih::Goodwill::Ledger.new.award(citizen, 50, reason: "test_seed")
          Service.issue_for(citizen)
        end

        test "a valid code is accepted once and rejected on the second attempt" do
          sign_in @operator

          post "/admin/bih/pozivnice/provjera", params: { entry_code: @invitation.entry_code }
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.invitation_checkins.create.valid", locale: :sr)
          assert @invitation.reload.entry_code_used_at.present?
          assert_equal "fulfilled", @invitation.reload.status

          post "/admin/bih/pozivnice/provjera", params: { entry_code: @invitation.entry_code }
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.invitation_checkins.create.already_used", locale: :sr)
        end

        test "an unconfirmed invitation is admitted with a warning and consumed exactly once" do
          other_citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          invitation = issue_invitation_for(other_citizen)
          assert_nil invitation.attendance_confirmed_at, "sanity check: attendance was never confirmed"

          sign_in @operator

          post "/admin/bih/pozivnice/provjera", params: { entry_code: invitation.entry_code }
          assert_response :success
          assert_includes response.body,
                          I18n.t("decidim.bih.admin.invitation_checkins.create.valid_unconfirmed", locale: :sr)
          assert invitation.reload.entry_code_used_at.present?
          assert_equal "fulfilled", invitation.reload.status

          post "/admin/bih/pozivnice/provjera", params: { entry_code: invitation.entry_code }
          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.invitation_checkins.create.already_used", locale: :sr)
        end

        test "a canceled invitation is rejected as no longer valid" do
          other_citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          invitation = issue_invitation_for(other_citizen)
          invitation.update!(status: "canceled")

          sign_in @operator
          post "/admin/bih/pozivnice/provjera", params: { entry_code: invitation.entry_code }

          assert_response :success
          assert_includes response.body,
                          I18n.t("decidim.bih.admin.invitation_checkins.create.no_longer_valid", locale: :sr)
          assert_nil invitation.reload.entry_code_used_at
        end

        test "an unknown code is rejected" do
          sign_in @operator
          post "/admin/bih/pozivnice/provjera", params: { entry_code: "MI-ZZZZZ-ZZZZZ" }

          assert_includes response.body, I18n.t("decidim.bih.admin.invitation_checkins.create.unknown", locale: :sr)
        end

        test "an anonymous visitor cannot check codes" do
          post "/admin/bih/pozivnice/provjera", params: { entry_code: @invitation.entry_code }

          assert_response :redirect
          assert_nil @invitation.reload.entry_code_used_at
        end

        test "a signed-in citizen cannot check codes" do
          sign_in @citizen
          post "/admin/bih/pozivnice/provjera", params: { entry_code: @invitation.entry_code }

          assert_response :redirect
          assert_nil @invitation.reload.entry_code_used_at
        end

        test "a rewards_operator with the narrow role can check codes at the door" do
          door_staff = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: door_staff,
            created_by: @operator,
            role: "rewards_operator",
            expires_at: 30.days.from_now
          )

          sign_in door_staff
          post "/admin/bih/pozivnice/provjera", params: { entry_code: @invitation.entry_code }

          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.admin.invitation_checkins.create.valid", locale: :sr)
          assert @invitation.reload.entry_code_used_at.present?
        end

        test "the entry code is filtered out of request logs" do
          # Rails precompiles config.filter_parameters into a merged Regexp the
          # first time any request is processed (config.precompile_filter_parameters
          # defaults to true), so by this point in the run the array no longer
          # holds a bare :entry_code symbol. Assert the actual filtering
          # behaviour instead of raw array membership.
          filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
                                                   .filter("entry_code" => @invitation.entry_code)

          assert_equal ActiveSupport::ParameterFilter::FILTERED, filtered["entry_code"]
        end
      end
    end
  end
end

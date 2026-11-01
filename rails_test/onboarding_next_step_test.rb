# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class OnboardingNextStepTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def next_step
          Decidim::Bih::Onboarding::NextStep.for(@citizen, organization: @organization)
        end

        def grant_sms!
          Decidim::Authorization.create!(user: @citizen, name: "sms", unique_id: "u-#{@citizen.id}", granted_at: Time.current)
        end

        def assign_komsiluk!
          komsiluk = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id, kind: "komsiluk", slug: "k-#{@citizen.id}",
            name: { "sr" => "Test komšiluk" }
          )
          Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization)
                                      .assign_komsiluk!(komsiluk, source: "dropdown")
        end

        test "without a pending sms authorization the next step is the phone form" do
          assert_equal "/sms/authorizations/new", next_step
        end

        test "with a pending sms authorization the next step is the link-sent page" do
          Decidim::Authorization.create!(user: @citizen, name: "sms", unique_id: "u-#{@citizen.id}", granted_at: nil)

          assert_equal Decidim::Bih.public_path("verifikacija/telefon"), next_step
        end

        test "with a granted sms authorization but no komsiluk the next step is the picker" do
          grant_sms!

          # The resolver is consulted from GET-time redirects, so asking must
          # never write. assert_no_difference wraps the FIRST call on purpose:
          # CitizenProfile.for_user is find_or_create_by!, so a resolver that
          # creates the row would still show no difference on a second call.
          assert_no_difference("Decidim::Bih::CitizenProfile.count") do
            assert_equal "#{Decidim::Bih.public_path("komsiluk")}?setup=1", next_step
          end
        end

        test "with sms and komsiluk but no welcome yet the next step is the welcome page" do
          grant_sms!
          assign_komsiluk!

          assert_equal Decidim::Bih.public_path("dobrodosli"), next_step
          # Asking is not being welcomed: the stamp is written by the
          # WelcomeController's POST, never here.
          assert_nil @citizen.reload.extended_data.to_h["mi_welcomed_at"]
        end

        test "with sms, komsiluk and the welcome behind them the next step is the account overview" do
          grant_sms!
          assign_komsiluk!
          Decidim::Bih::Onboarding::Welcome.mark!(@citizen)

          assert_equal "#{Decidim::Bih.public_path("moj-nalog")}?setup=1", next_step
        end
      end
    end
  end
end

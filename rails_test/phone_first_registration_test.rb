# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class PhoneFirstRegistrationTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          Decidim::Bih.phone_first_registration = true
        end

        teardown { Decidim::Bih.phone_first_registration = false }

        test "core registration offers the topic choice without the newsletter submit blocker" do
          get "/users/sign_up"
          assert_response :success
          assert_select "input[type=checkbox][name='user[newsletter]'][checked]", count: 1
          assert_select "details.mi-notification-registration-details summary", count: 1
          assert_select "[data-controller='user-registration-form']", count: 0
          assert_select "#sign-up-newsletter-modal", count: 0
        end

        def register!(email: "nova-#{SecureRandom.hex(3)}@example.org")
          post "/users", params: {
            user: { name: "Nova Građanka", email:, password: "Stronger-password-2026", tos_agreement: "1", newsletter: "0" }
          }
          Decidim::User.find_by(email:, organization: @organization)
        end

        # The Decidim :user factory leaves the account unconfirmed; Devise's
        # before_create fills confirmation_token, but generate it explicitly so
        # the test does not silently depend on that callback staying in place.
        def unconfirmed_citizen!
          user = FactoryBot.create(:user, organization: @organization)
          user.send(:generate_confirmation_token!) if user.confirmation_token.blank?
          user.reload
        end

        def account_setup_path
          "#{Decidim::Bih.public_path("moj-nalog")}?setup=1"
        end

        test "a phone-first sign-up is confirmed at once, signed in, and sent to the phone form" do
          user = register!

          assert user.confirmed?, "confirmed_at is set without an e-mail round trip"
          assert_redirected_to Decidim::Bih::Onboarding::NextStep::SMS_NEW_PATH
          follow_redirect!
          assert_response :success, "the citizen is signed in and may open the phone form"
          assert_no_enqueued_emails
        end

        test "with the switch off Decidim behaves as before" do
          Decidim::Bih.phone_first_registration = false
          user = register!

          refute user.confirmed?
          assert_redirected_to "/users/sign_in?redirect_url=#{CGI.escape(account_setup_path)}"
        end

        test "an e-mail confirmation signs the citizen in and continues the phone-first chain" do
          citizen = unconfirmed_citizen!

          get "/users/confirmation?confirmation_token=#{citizen.confirmation_token}"

          assert citizen.reload.confirmed?
          assert_redirected_to Decidim::Bih::Onboarding::NextStep::SMS_NEW_PATH
          follow_redirect!
          # /sms/authorizations/* is mounted inside Devise's authenticate(:user)
          # constraint, so a 200 here is only reachable from a signed-in session.
          assert_response :success, "the confirmation signed the citizen in"
        end

        test "with the switch off an e-mail confirmation signs the citizen in and keeps the setup checklist" do
          Decidim::Bih.phone_first_registration = false
          citizen = unconfirmed_citizen!

          get "/users/confirmation?confirmation_token=#{citizen.confirmation_token}"

          assert citizen.reload.confirmed?
          assert_redirected_to account_setup_path
          follow_redirect!
          # The account overview is behind authenticate_user!, so a 200 here is
          # the proof that the session is signed in rather than bounced to login.
          assert_response :success, "the confirmation signed the citizen in"
        end
      end
    end
  end
end

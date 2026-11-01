# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # /p/<nadimak>: the short, sayable invite link. It only redirects to the
      # registration form with the code; the form does the capturing.
      class ShortInviteLinkTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @referrer = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana_poziva")
          @previous_short = Decidim::Bih.invite_short_path
        end

        teardown do
          Decidim::Bih.invite_short_path = @previous_short
        end

        def registration = Decidim::Bih.public_path("registracija")

        test "the mounted short link redirects to the registration form carrying the code" do
          get Decidim::Bih.public_path("p/ana_poziva")

          assert_response :found
          assert_redirected_to "#{registration}?ref=ana_poziva"
        end

        test "a code that is not nickname-shaped is dropped, and the citizen still gets the form" do
          get Decidim::Bih.public_path("p/#{"a" * 61}")

          assert_response :found
          assert_redirected_to registration
        end

        test "following the short link attributes the registration like the long one" do
          get Decidim::Bih.public_path("p/ana_poziva")
          follow_redirect!
          assert_response :success
          assert_select "input#mi-registration-ref[value=?]", "ana_poziva"
        end

        test "with the host setting, the invite tab shows the short link and a QR code to download" do
          Decidim::Bih.invite_short_path = "/p"
          sign_in @referrer

          get Decidim::Bih.public_path("zajednistvo?tab=pozovi")

          assert_response :success
          assert_includes response.body, "#{request.base_url}/p/ana_poziva"
          assert_select ".mi-invite-qr svg"
          assert_select ".mi-invite-qr a[download='pozovi-ana_poziva.svg']"
          refute_includes response.body, "<?xml", "the inline SVG carries no XML prolog"
        end

        test "without the host setting the tab keeps the long link and still offers the QR" do
          Decidim::Bih.invite_short_path = nil
          sign_in @referrer

          get Decidim::Bih.public_path("zajednistvo?tab=pozovi")

          assert_includes response.body, "#{registration}?ref=ana_poziva"
          assert_select ".mi-invite-qr svg"
        end
      end
    end
  end
end

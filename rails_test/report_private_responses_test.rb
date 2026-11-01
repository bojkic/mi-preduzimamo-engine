# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The two report responses that must never sit in a shared cache: "moje
      # prijave" (one citizen's own list) and the private status-token tracker.
      #
      # SIGNED IN on purpose. Decidim's Headers::HttpCachingDisabler populates
      # the response's cache_control API in an earlier before_action, and at
      # commit time ActionDispatch merges that API OVER whatever a raw
      # set_header wrote — so a raw header shipped "no-cache, no-store" on
      # every signed-in response and silently dropped `private`, the directive
      # that keeps a citizen's own reports out of a shared proxy. Anonymous
      # responses kept it, which is why it went unnoticed. The assertion is on
      # the wire header for exactly that reason, and it is the only thing that
      # proves `protect_*` really runs after the disabler.
      class ReportPrivateResponsesTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @report = Decidim::Bih::Report.create!(
            organization: @organization,
            author: @citizen,
            description: "Broken pavement in front of the school.",
            category: "putevi",
            severity: "normalan",
            status: "primljeno",
            address: "Harness street 1",
            latitude: 44.758,
            longitude: 19.214
          )
          sign_in @citizen
        end

        def mount = Decidim::Bih.normalized_public_mount_path

        def assert_private_response(path)
          cache_control = response.headers["Cache-Control"].to_s
          assert_includes cache_control, "no-store", path
          assert_includes cache_control, "private",
                          "#{path}: a signed-in response must keep `private` (#{cache_control})"
          assert_equal "no-cache", response.headers["Pragma"], path
          assert_equal "strict-origin", response.headers["Referrer-Policy"], path
          assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"], path
        end

        test "a citizen's own report list is private and never stored" do
          path = "#{mount}/prijave?view=mine"

          get path

          assert_response :success
          assert_private_response(path)
        end

        test "the private status tracker is private and never stored" do
          path = "#{mount}/prijave/#{@report.reference}/status/#{@report.status_token}"

          get path

          assert_response :success
          assert_private_response(path)
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ScreenTest < ActionDispatch::IntegrationTest
        setup do
          # The 2026 race closed 14.10 20:00; scoring and refresh run only while it is open.
          travel_to Time.utc(2026, 10, 1, 10)
          @organization = create_organization
          host! @organization.host
          Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-grad", zona: "grad", name: { "sr" => "Centar" }
          )
          Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-selo", zona: "selo", name: { "sr" => "Dvorovi" }
          )
          Decidim::Bih::LocalArea.where(organization: @organization).each do |area|
            user = FactoryBot.create(:user, :confirmed, organization: @organization)
            Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(8), granted_at: Time.utc(2026, 9, 10))
            Decidim::Bih::CitizenProfile.create!(organization: @organization, user:, komsiluk: area, assigned_at: Time.utc(2026, 9, 10), source: "dropdown")
          end
          Decidim::Bih::Setting.put(@organization, "screen", "wifi_ssid", "MI-GOSTI")
          Decidim::Bih::Setting.put(@organization, "screen", "wifi_password", "dobrodosli")
          Decidim::Bih::Race::Standings.new(@organization).refresh!(force: true)
        end

        test "the screen renders without a login" do
          get "#{public_mount_path}/ekran"

          assert_response :success
          assert_match "Centar", response.body
          assert_match "Dvorovi", response.body
        end

        test "the screen shows the venue wifi so people can join" do
          get "#{public_mount_path}/ekran"

          assert_match "MI-GOSTI", response.body
          assert_match "dobrodosli", response.body
        end

        test "the json endpoint returns the same aggregate figures" do
          get "#{public_mount_path}/ekran.json"

          assert_response :success
          payload = JSON.parse(response.body)

          assert payload.has_key?("registered")
          assert payload.has_key?("reports")
          assert payload.has_key?("komsiluci_with_reports")
          assert_equal "Centar", payload.dig("leaders", "grad", "name")
          assert_equal "Dvorovi", payload.dig("leaders", "selo", "name")
        end

        test "the screen exposes no personal data" do
          get "#{public_mount_path}/ekran.json"

          refute_match(/email|phone|nickname|decidim_user_id/, response.body)
        end

        # Test 8 from the spec: the markup must carry the numbers server-side so a
        # failed refresh leaves the last figures on screen rather than an error.
        test "the first paint is server rendered so a dead network keeps the numbers" do
          get "#{public_mount_path}/ekran"

          assert_match(/data-screen-registered=/, response.body)
          assert_match(/data-screen-refresh-ms="30000"/, response.body)
        end

        # Fix round 1 / FINDING 1: there is no JS test harness in this engine, so
        # this is a SOURCE-LEVEL tripwire, not a behavioural test — it greps the
        # rendered <script> for the two shapes that keep a failed 30s poll from
        # blanking the screen, rather than exercising a fetch failure in a real
        # browser. It proves the guard and the empty catch handler are still
        # present in source; it cannot prove the JS actually runs that way.
        test "the refresh script never blanks a figure on a failed poll" do
          get "#{public_mount_path}/ekran"

          script = response.body[%r{<script>.*</script>}m]
          assert script, "Expected the screen to ship its refresh <script>"

          set_fn = script[/function set\(field, value\)\s*\{.*?\n\s*\}/m]
          assert set_fn, "Expected a set(field, value) helper in the refresh script"

          guard_at = set_fn =~ /value\s*===\s*null\s*\|\|\s*value\s*===\s*undefined\s*\)\s*return/
          assign_at = set_fn =~ /textContent\s*=\s*value/
          assert guard_at, "Expected set() to bail out before assigning a null/undefined value"
          assert assign_at, "Expected set() to assign the field's textContent"
          assert guard_at < assign_at, "Expected the nullish guard to run before the textContent assignment"

          catch_body = script[/\.catch\(function\s*\(\)\s*\{(.*?)\}\);/m, 1]
          assert catch_body, "Expected a .catch handler on the refresh fetch"
          refute_match(/set\(/, catch_body, "The failure handler must not touch any field")
          refute_match(/textContent/, catch_body, "The failure handler must not touch any field")
        end

        # Fix round 1 / FINDING 2: the wifi credentials must never fold into the
        # JSON payload — that endpoint is fetchable by anyone who knows the URL.
        # MI-GOSTI/dobrodosli are the setup fixture's distinctive values, so this
        # cannot pass by accident (they appear nowhere else in the figures).
        test "the json endpoint never leaks the venue wifi credentials" do
          get "#{public_mount_path}/ekran.json"

          assert_response :success
          refute_match "MI-GOSTI", response.body
          refute_match "dobrodosli", response.body
        end

        private

        # This harness mounts the engine wherever script/decidim_bih_rails_test's
        # MOUNT_PATH (default "/moja-platforma") says, not at the "/biceriseno"
        # default used by a real host app install. Same resolution
        # PublicSurfaceSmokeTest and RaceLeaderboardTabTest use, so the URLs this
        # test issues always match wherever this harness run actually mounted
        # the engine.
        def public_mount_path
          Decidim::Bih.normalized_public_mount_path
        end
      end
    end
  end
end

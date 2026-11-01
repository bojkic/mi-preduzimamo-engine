# frozen_string_literal: true

require "test_helper"
require "nokogiri"

module Decidim
  module Bih
    module RailsHarness
      class RaceLeaderboardTabTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          # The 2026 race closed 14.10 20:00; scoring and refresh run only while it is open.
          travel_to Time.utc(2026, 10, 1, 10)
          @organization = create_organization
          host! @organization.host
          Decidim::Bih.race_window_from = "2026-09-06 00:00:00"
          Decidim::Bih.race_window_to = "2026-10-14 20:00:00"
          @inside = Time.zone.parse("2026-09-20 12:00:00")
          @grad = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-grad", zona: "grad", name: { "sr" => "Centar" }
          )
          @selo = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-selo", zona: "selo", name: { "sr" => "Dvorovi" }
          )
          Decidim::Bih::Race::Standings.new(@organization).refresh!(force: true)
        end

        teardown do
          Decidim::Bih.race_window_from = nil
          Decidim::Bih.race_window_to = nil
        end

        test "the trka tab renders both league leaders and the table" do
          get "#{public_mount_path}/zajednistvo?tab=trka"

          assert_response :success
          assert_match "Centar", response.body
          assert_match "Dvorovi", response.body
          assert_match I18n.t("decidim.bih.community_hub.race.leader_grad", locale: :sr), response.body
          assert_match I18n.t("decidim.bih.community_hub.race.leader_selo", locale: :sr), response.body
        end

        # Falsification target: with only one komšiluk per zone (the setup
        # fixture above), both cards showing `rows.first` would be
        # indistinguishable from each card showing its own zone leader — every
        # assertion in the test above would still pass. This test adds a SECOND
        # grad komšiluk that outscores everyone, so the overall top-of-table row
        # is unambiguously a grad row and NOT the selo leader, then asserts
        # against the leader-card markup specifically (`.mi-race__leader--<zone>`,
        # see _trka.html.erb) rather than "the name appears somewhere in the
        # body" — a build where both cards were wired to rows.first must fail
        # this test's selo-card assertions.
        test "each leader card shows its own zone's leader, not the top of the table" do
          novo_naselje = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-grad-2", zona: "grad",
            name: { "sr" => "Novo Naselje" }
          )
          5.times { citizen(novo_naselje) } # score 5 — highest overall, top of table
          3.times { citizen(@selo) } # score 3 — selo's real (non-zero) leader
          citizen(@grad) # score 1 — stays in the table, well below both leaders

          Decidim::Bih::Race::Standings.new(@organization).refresh!(force: true)

          get "#{public_mount_path}/zajednistvo?tab=trka"
          assert_response :success

          doc = Nokogiri::HTML(response.body)
          grad_card = doc.at_css(".mi-race__leader--grad")
          selo_card = doc.at_css(".mi-race__leader--selo")

          assert grad_card, "expected a grad leader card"
          assert selo_card, "expected a selo leader card"

          assert_includes grad_card.text, "Novo Naselje"
          assert_includes selo_card.text, "Dvorovi"
          refute_includes selo_card.text, "Novo Naselje",
                          "the selo card must name the selo leader, not the overall top-of-table grad row"
        end

        test "the zone filter narrows the table to that league" do
          get "#{public_mount_path}/zajednistvo?tab=trka&zona=selo"

          assert_response :success
          assert_match "Dvorovi", response.body
        end

        test "an unknown zone value falls back to all rather than erroring" do
          get "#{public_mount_path}/zajednistvo?tab=trka&zona=nonsense"

          assert_response :success
        end

        # Test 6 from the spec: the page reads the cache, it does not score.
        test "rendering the tab never runs the scorer" do
          called = false
          stub = ->(*_args, **_kwargs) { called = true }

          Decidim::Bih::Race::Scorer.stub(:new, stub) do
            get "#{public_mount_path}/zajednistvo?tab=trka"
          end

          assert_response :success
          refute called, "the public leaderboard must read the cached table only"
        end

        # The standings tab and the invite tab are siblings on one hub with
        # nothing linking them, so a citizen reading their own rank — the moment
        # they most want to move it — had no way to act on it. Registrations are
        # worth 1 point each and dominate the score, so inviting IS the lever.
        test "a signed-in citizen sees an invite CTA under their own komšiluk row" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::CitizenProfile.create!(
            organization: @organization, decidim_user_id: user.id,
            komsiluk_id: @grad.id, source: "dropdown", assigned_at: @inside
          )
          sign_in user

          get "#{public_mount_path}/zajednistvo?tab=trka"

          assert_response :success
          doc = Nokogiri::HTML(response.body)
          cta = doc.at_css(".mi-race__invite a")
          assert cta, "the your-komšiluk row carries a way to act on the rank"
          assert_equal Decidim::Bih.invite_path, cta["href"]
          assert_match I18n.t("decidim.bih.community_hub.race.invite_cta", locale: :sr), cta.text
        end

        # No rank, nothing to act on, and no reason to push a signed-out visitor
        # at an invite link they cannot generate — the invite tab needs a
        # nickname, which only a registered citizen has.
        test "a signed-out visitor sees no invite CTA on the leaderboard" do
          get "#{public_mount_path}/zajednistvo?tab=trka"

          assert_response :success
          assert_nil Nokogiri::HTML(response.body).at_css(".mi-race__invite")
        end

        test "a signed-in citizen with no komšiluk chosen sees no your-komšiluk row" do
          sign_in FactoryBot.create(:user, :confirmed, organization: @organization)

          get "#{public_mount_path}/zajednistvo?tab=trka"

          assert_response :success
          doc = Nokogiri::HTML(response.body)
          assert_nil doc.at_css(".mi-race__mine"),
                     "a citizen with no CitizenProfile/komšiluk chosen must not see the your-komšiluk row"
        end

        test "a signed-in citizen whose komšiluk has no standing row yet sees no your-komšiluk row" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(8), granted_at: @inside)

          # Created AFTER setup's refresh!, so this komšiluk was never scored
          # into the cached table — Race::Standing#for_komsiluk returns nil for
          # it, which is exactly the nil-guard race_viewer_row exists to survive.
          fresh_komsiluk = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-fresh", zona: "grad",
            name: { "sr" => "Novi Kraj" }
          )
          Decidim::Bih::CitizenProfile.create!(
            organization: @organization, decidim_user_id: user.id,
            komsiluk_id: fresh_komsiluk.id, source: "dropdown", assigned_at: @inside
          )

          sign_in user

          get "#{public_mount_path}/zajednistvo?tab=trka"

          assert_response :success
          doc = Nokogiri::HTML(response.body)
          assert_nil doc.at_css(".mi-race__mine"),
                     "a komšiluk with no cached standing row must not render the your-komšiluk row"
        end

        private

        # The rails_test generated-host harness mounts Decidim::Bih::Engine at
        # MOUNT_PATH (default "/moja-platforma", see script/decidim_bih_rails_test),
        # not at the "/biceriseno" default used by a real host app install. Same
        # resolution PublicSurfaceSmokeTest uses, so the URLs this test issues
        # always match wherever this harness run actually mounted the engine.
        def public_mount_path
          Decidim::Bih.normalized_public_mount_path
        end

        # Mirrors RaceStandingsTest's helper: a verified, komšiluk-assigned
        # citizen, the minimum fixture the Scorer counts toward `registered`.
        def citizen(komsiluk, at: @inside)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(8), granted_at: at)
          Decidim::Bih::CitizenProfile.create!(
            organization: @organization, decidim_user_id: user.id,
            komsiluk_id: komsiluk.id, source: "dropdown", assigned_at: at
          )
          user
        end
      end
    end
  end
end

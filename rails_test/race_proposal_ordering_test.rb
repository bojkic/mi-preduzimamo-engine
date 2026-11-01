# frozen_string_literal: true

require "test_helper"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module RailsHarness
      # Drives the REAL Decidim::Proposals::Orderable#reorder path and the
      # REAL Decidim::Reportable#not_hidden moderation scope through an actual
      # HTTP request to the proposals index controller, rather than a
      # hand-built query that would pass regardless of what the shipped
      # ordering/visibility code does.
      #
      # See race_does_not_affect_voting_test.rb for the schema, source, and
      # per-vote-weight layers; this file is Layer 3's real-controller half
      # for the two remaining legs of the promise: ranking and visibility.
      class RaceProposalOrderingTest < ActionDispatch::IntegrationTest
        setup do
          # The 2026 race closed 14.10 20:00; scoring and refresh run only while it is open.
          travel_to Time.utc(2026, 10, 1, 10)
          @organization = create_organization
          host! @organization.host
          @grad = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-grad", zona: "grad", name: { "sr" => "Centar" }
          )
          @selo = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-selo", zona: "selo", name: { "sr" => "Dvorovi" }
          )
          Decidim::Bih.race_window_from = "2026-09-06 00:00:00"
          Decidim::Bih.race_window_to = "2026-10-14 20:00:00"
          @inside = Time.zone.parse("2026-09-20 12:00:00")
        end

        teardown do
          Decidim::Bih.race_window_from = nil
          Decidim::Bih.race_window_to = nil
        end

        def citizen(komsiluk, at: @inside)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(8), granted_at: at)
          Decidim::Bih::CitizenProfile.create!(
            organization: @organization, decidim_user_id: user.id,
            komsiluk_id: komsiluk.id, source: "dropdown", assigned_at: at
          )
          user
        end

        def standings = Decidim::Bih::Race::Standings.new(@organization)

        def manufacture_score_gap!
          10.times { citizen(@grad) }
          standings.refresh!(force: true)
          rows = standings.rows.index_by(&:slug_for_test)
          assert_operator rows["k-grad"].score, :>, rows["k-selo"].score,
                          "fixture setup must actually produce a score gap, or this test proves nothing"
        end

        test "the real proposal index ranks by votes, never by komšiluk score, under the actual Orderable#reorder path" do
          manufacture_score_gap!

          component = FactoryBot.create(:proposal_component, :with_votes_enabled, organization: @organization)
          top_scoring_author = citizen(@grad)
          zero_scoring_author = citizen(@selo)

          # The underdog: authored by the RACE LEADER, but gets fewer votes.
          underdog = FactoryBot.create(
            :proposal, component:, users: [top_scoring_author], published_at: @inside,
                       title: { "sr" => "Prijedlog vodeceg komsiluka" }
          )
          # The favourite: authored by a komšiluk with ZERO race points, but
          # gets more votes.
          favourite = FactoryBot.create(
            :proposal, component:, users: [zero_scoring_author], published_at: @inside,
                       title: { "sr" => "Prijedlog komsiluka bez bodova" }
          )

          FactoryBot.create(:proposal_vote, proposal: underdog, author: citizen(@selo))
          3.times { FactoryBot.create(:proposal_vote, proposal: favourite, author: citizen(@grad)) }

          get Decidim::EngineRouter.main_proxy(component).proposals_path(order: "most_voted")

          assert_response :success
          body = response.body
          assert_includes body, "Prijedlog vodeceg komsiluka"
          assert_includes body, "Prijedlog komsiluka bez bodova"
          # If Orderable#reorder ever consulted komšiluk score, the far
          # higher-scoring underdog's author could float above the favourite
          # despite fewer votes. It must not: the zero-score favourite, with
          # 3 votes, must render before the 1-vote underdog.
          assert_operator body.index("Prijedlog komsiluka bez bodova"), :<, body.index("Prijedlog vodeceg komsiluka"),
                          "the real most_voted order must rank by votes, not by the author's komšiluk score"
        end

        test "a highest-scoring komšiluk's hidden proposal is excluded from the real listing exactly like anyone else's" do
          manufacture_score_gap!

          component = FactoryBot.create(:proposal_component, organization: @organization)
          top_scoring_author = citizen(@grad)

          hidden_proposal = FactoryBot.create(
            :proposal, component:, users: [top_scoring_author], published_at: @inside,
                       title: { "sr" => "Sakriveni prijedlog vodeceg komsiluka" }
          )
          FactoryBot.create(
            :moderation, :hidden, reportable: hidden_proposal, participatory_space: hidden_proposal.participatory_space
          )

          get Decidim::EngineRouter.main_proxy(component).proposals_path

          assert_response :success
          # Moderation, not komšiluk score, decides visibility: a real
          # Decidim::Moderation#hidden_at hides this proposal from the public
          # index (Decidim::Reportable#not_hidden, exercised by the
          # controller's real search_collection) exactly as it would for the
          # lowest-scoring komšiluk's citizen.
          assert_not_includes response.body, "Sakriveni prijedlog vodeceg komsiluka"
        end
      end
    end
  end
end

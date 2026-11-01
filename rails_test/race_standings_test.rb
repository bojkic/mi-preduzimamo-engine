# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class RaceStandingsTest < ActiveSupport::TestCase
        setup do
          # The 2026 race closed 14.10 20:00; scoring and refresh run only while it is open.
          travel_to Time.utc(2026, 10, 1, 10)
          # Save shared state before factories: teardown also runs when setup
          # raises, and must never replace the process cache with nil.
          @previous_cache = Rails.cache
          Rails.cache = ActiveSupport::Cache::MemoryStore.new
          @previous_race_window = [Decidim::Bih.race_window_from, Decidim::Bih.race_window_to]
          Decidim::Bih.race_window_from = "2026-09-06 00:00:00"
          Decidim::Bih.race_window_to = "2026-10-14 20:00:00"
          @organization = create_organization
          @inside = Time.zone.parse("2026-09-20 12:00:00")
          @a = area("k-a", "grad")
          @b = area("k-b", "grad")
          @c = area("k-c", "selo")
        end

        teardown do
          travel_back
          Decidim::Bih.race_window_from, Decidim::Bih.race_window_to = @previous_race_window if instance_variable_defined?(:@previous_race_window)
          if instance_variable_defined?(:@previous_cache)
            Rails.cache.clear
            Rails.cache = @previous_cache
          end
        end

        def area(slug, zona)
          Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug:, zona:, name: { "sr" => slug }
          )
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

        def report_for(user, at: @inside)
          Decidim::Bih::Report.create!(
            organization: @organization, decidim_user_id: user.id, reference: SecureRandom.hex(6),
            description: "x", status: "u_obradi", created_at: at
          )
        end

        def standings = Decidim::Bih::Race::Standings.new(@organization)

        test "refresh writes one row per komšiluk with overall and in-zone ranks" do
          report_for(citizen(@b))
          citizen(@a)

          assert_equal 3, standings.refresh!

          rows = standings.rows.index_by(&:slug_for_test)

          assert_equal 1, rows["k-b"].rank_overall
          assert_equal 1, rows["k-b"].rank_in_zone
          assert_equal 2, rows["k-a"].rank_overall
          assert_equal 2, rows["k-a"].rank_in_zone
          assert_equal 1, rows["k-c"].rank_in_zone, "the only selo komšiluk leads its own league"
        end

        # Test 12 from the spec.
        test "the leader of each league comes from that league, not from the top of the table" do
          report_for(citizen(@b))

          standings.refresh!

          assert_equal @b.id, standings.leader("grad").komsiluk_id
          assert_nil standings.leader("selo"), "zero participation must not manufacture a winner"
        end

        # Test 11 from the spec.
        test "filtering by zone renumbers positions inside that zone" do
          report_for(citizen(@b))
          citizen(@a)
          standings.refresh!

          assert_equal [1, 2], standings.rows(zone: "grad").map(&:rank_in_zone)
          assert_equal %w(k-b k-a), standings.rows(zone: "grad").map(&:slug_for_test)
        end

        test "a second refresh inside the interval is skipped, and force overrides it" do
          standings.refresh!

          assert_equal 0, standings.refresh!, "the 10-minute guard suppresses the second run"
          assert_equal 3, standings.refresh!(force: true)
        end

        # Test 15 from the spec.
        test "a frozen standing is never recomputed" do
          report_for(citizen(@b))
          standings.refresh!
          freeze_reviewed!

          assert_predicate standings, :final?
          frozen_score = standings.rows.first.score

          report_for(citizen(@a))
          report_for(citizen(@a))
          standings.refresh!(force: true)

          assert_equal frozen_score, standings.rows.first.score, "published final numbers must not drift"
        end

        test "for_komsiluk finds a komšiluk that is not in the top of the table" do
          standings.refresh!

          assert_equal @c.id, standings.for_komsiluk(@c.id).komsiluk_id
        end

        # Fix round 1, Finding 1: a NullStore reports every write as
        # successful, so unless_exist can never actually block a second
        # writer there. The timestamp backstop must suppress the second
        # refresh anyway, without any help from the cache.
        test "a NullStore cannot claim the slot, but the timestamp backstop still suppresses a second refresh" do
          Rails.cache = ActiveSupport::Cache::NullStore.new

          assert_equal 3, standings.refresh!
          assert_equal 0, standings.refresh!, "the timestamp backstop must catch what NullStore's always-true write cannot"
        end

        test "force still refreshes even when the standing was computed inside the interval" do
          standings.refresh!

          assert_equal 3, standings.refresh!(force: true), "force must bypass the timestamp backstop as well as the cache claim"
        end

        test "a frozen standing still refuses force: true" do
          standings.refresh!
          freeze_reviewed!

          assert_equal 0, standings.refresh!(force: true), "final? must win over force, always"
        end

        test "finalization without an authenticated review never writes rows" do
          standings.refresh!
          assert_raises(Decidim::ActionForbidden) { standings.freeze! }
          assert_not standings.final?
        end

        def freeze_reviewed!
          admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          review = Decidim::Bih::Race::Review.new(@organization)
          review.baseline!(actor: admin, reason: "Test baseline")
          travel_to Time.utc(2026, 10, 14, 18, 0, 1)
          ed = review.capture!
          ed.snapshot.fetch("items").each do |item|
            next unless item.dig("facts", "review_state").in?(%w(pending needs_information))

            review.decide!(actor: admin, reason: "Reviewed source", item_key: item["key"], include_item: item["eligible"], expected_digest: ed.snapshot_digest)
          end
          winners = review.preview.group_by { |row| row[:zona] }.filter_map { |zone, rows| [zone, "none"] if rows.first[:score].zero? }.to_h
          settings = {
            review_closes_at: "2026-10-14T18:00:00Z", vote_starts_at: "2026-10-20T08:00:00Z", vote_ends_at: "2026-10-25T08:00:00Z",
            tie_procedure: "Admin review", zero_entry_procedure: "No award", project_owner: "Foundation", winners:
          }
          review.settings!(actor: admin, reason: "Review setup", values: settings)
          standings.freeze!(actor: admin, reason: "Approved", expected_digest: ed.snapshot_digest, expected_revision: ed.events.maximum(:id))
        end
      end
    end
  end
end

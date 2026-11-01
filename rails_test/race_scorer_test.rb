# frozen_string_literal: true

require "test_helper"
# test_helper.rb loads decidim/core and decidim/budgets factories only; this
# is the sole rails_test file that needs a citizen-authored proposal, so pull
# the proposals factory in locally rather than widen the shared helper.
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module RailsHarness
      # Proves the published scoring rule against Postgres:
      #   rezultat = registrovani × 1 + prijave × 2 + prijedlozi × 3
      # with at most 5 reports and 3 proposals counted per person.
      class RaceScorerTest < ActiveSupport::TestCase
        WINDOW_FROM = "2026-09-06 00:00:00"
        WINDOW_TO = "2026-10-14 20:00:00"

        setup do
          @organization = create_organization
          Decidim::Bih.race_window_from = WINDOW_FROM
          Decidim::Bih.race_window_to = WINDOW_TO
          # The rails_test disposable host does not set config.time_zone (unlike
          # production's decidim_app, which pins Europe/Sarajevo). Race::Config
          # always parses the window against an explicit Europe/Sarajevo zone
          # regardless of the ambient Time.zone, so pin it here too — otherwise
          # this fixture's bare Time.zone.parse boundary values silently drift by
          # the +02:00 CEST offset against the window this test is asserting on.
          @previous_time_zone = Time.zone
          Time.zone = "Europe/Sarajevo"
          @grad = area("k-grad", "grad")
          @selo = area("k-selo", "selo")
          @inside = Time.zone.parse("2026-09-20 12:00:00")
        end

        teardown do
          Decidim::Bih.race_window_from = nil
          Decidim::Bih.race_window_to = nil
          Time.zone = @previous_time_zone
        end

        def area(slug, zona)
          Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug:, zona:, name: { "sr" => slug }
          )
        end

        # A citizen who verified their phone AND picked a komšiluk.
        def citizen(komsiluk, verified_at: @inside, assigned_at: @inside)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(8), granted_at: verified_at)
          Decidim::Bih::CitizenProfile.create!(
            organization: @organization, decidim_user_id: user.id,
            komsiluk_id: komsiluk.id, source: "dropdown", assigned_at:
          )
          user
        end

        def report_for(user, at: @inside, status: "u_obradi", **attributes)
          Decidim::Bih::Report.create!(
            organization: @organization, decidim_user_id: user.id, reference: SecureRandom.hex(6),
            description: "x", status:, created_at: at, **attributes
          )
        end

        # A published proposal component, created once per test and reused.
        def proposal_component
          @proposal_component ||= FactoryBot.create(:proposal_component, organization: @organization)
        end

        # A citizen-authored, published proposal — NOT an official one, so
        # `decidim_author_type` on its coauthorship is 'Decidim::UserBaseEntity'
        # and the scorer counts it.
        def proposal_for(user, at: @inside)
          FactoryBot.create(:proposal, component: proposal_component, users: [user], published_at: at)
        end

        def rows_by_slug
          Decidim::Bih::Race::Scorer.new(organization: @organization).rows.index_by { |r| r[:slug] }
        end

        # Test 1 from the spec.
        test "score is registered + 2×reports + 3×proposals" do
          user = citizen(@grad)
          2.times { report_for(user) }

          row = rows_by_slug["k-grad"]

          assert_equal 1, row[:registered]
          assert_equal 2, row[:reports]
          assert_equal 0, row[:proposals]
          assert_equal 5, row[:score], "1×1 + 2×2 = 5"
        end

        # Test 2 from the spec: the sixth report does not raise the komšiluk score.
        test "only the first five reports of one person count towards the komšiluk" do
          user = citizen(@grad)
          6.times { |i| report_for(user, at: @inside + i.minutes) }

          row = rows_by_slug["k-grad"]

          assert_equal 5, row[:reports], "the sixth report must not raise the komšiluk score"
          assert_equal 11, row[:score], "1 + 5×2"
        end

        # Test 2 from the spec, proposal half: the fourth proposal does not
        # raise the komšiluk score either — the cap applies per-person to
        # BOTH activity types, not just reports.
        test "only the first three proposals of one person count towards the komšiluk" do
          user = citizen(@grad)
          4.times { |i| proposal_for(user, at: @inside + i.minutes) }

          row = rows_by_slug["k-grad"]

          assert_equal 3, row[:proposals], "the fourth proposal must not raise the komšiluk score"
          assert_equal 10, row[:score], "1 + 3×3"
        end

        # Test 3 from the spec.
        test "an unverified citizen counts for nothing, not even their reports" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::CitizenProfile.create!(
            organization: @organization, decidim_user_id: user.id,
            komsiluk_id: @grad.id, source: "dropdown", assigned_at: @inside
          )
          report_for(user)
          proposal_for(user)

          row = rows_by_slug["k-grad"]

          assert_equal 0, row[:registered], "no granted sms authorization → not registered"
          assert_equal 0, row[:reports]
          assert_equal 0, row[:proposals]
          assert_equal 0, row[:score]
        end

        # Test 4 from the spec.
        test "a report rejected in moderation is removed from the score" do
          user = citizen(@grad)
          report_for(user)
          report_for(user, status: "odbijeno")

          assert_equal 1, rows_by_slug["k-grad"][:reports]
        end

        test "a non-rejected duplicate earns no race credit and never consumes the report cap" do
          user = citizen(@grad)
          main = report_for(user, at: @inside - 1.month)
          duplicate = report_for(user, at: @inside, duplicate_of: main)
          valid = 5.times.map { |index| report_for(user, at: @inside + (index + 1).minutes) }
          snapshot = Decidim::Bih::Race::SnapshotBuilder.new(organization: @organization).call
          candidate = snapshot.fetch("items").find { |item| item["key"] == "report:#{duplicate.id}" }
          assert_equal false, candidate.fetch("eligible")
          assert_equal main.id, candidate.dig("facts", "duplicate_of")
          calculator = Decidim::Bih::Race::Calculator.new(snapshot)
          row = calculator.rows.find { |item| item[:komsiluk_id] == @grad.id }
          assert_equal 5, row[:reports]
          assert_equal 11, row[:score]
          assert_equal valid.last.created_at, row[:reached_at]
          assert_equal "duplicate", calculator.evidence.find { |item| item["key"] == candidate["key"] }["reason"]
          assert_equal "counted", calculator.evidence.find { |item| item["key"] == "report:#{valid.last.id}" }["reason"]

          # Rejecting the main problem does not silently revoke the submitted
          # duplicate's personal five; its race credit remains zero either way.
          main.update!(status: "odbijeno")
          assert_equal 5, Decidim::Bih::Goodwill::ReportEntitlement.outcome_target(duplicate)
          assert_equal 5, rows_by_slug.fetch("k-grad")[:reports]
          duplicate.update!(duplicate_of: nil)
          cleared = Decidim::Bih::Race::SnapshotBuilder.new(organization: @organization).call
          assert_equal true, cleared.fetch("items").find { |item| item["key"] == candidate["key"] }.fetch("eligible")
        end

        # Test 5 from the spec.
        test "activity outside the window does not count" do
          before = Time.zone.parse("2026-09-05 23:59:59")
          after = Time.zone.parse("2026-10-14 20:00:00")
          user = citizen(@grad)
          report_for(user, at: before)
          report_for(user, at: after)

          assert_equal 0, rows_by_slug["k-grad"][:reports]
        end

        test "a registration completed before the window opens does not count" do
          citizen(@selo, verified_at: Time.zone.parse("2026-08-01 10:00"), assigned_at: Time.zone.parse("2026-08-02 10:00"))

          assert_equal 0, rows_by_slug["k-selo"][:registered]
        end

        test "registration counts at the later of verification and komšiluk choice" do
          citizen(@selo, verified_at: Time.zone.parse("2026-08-01 10:00"), assigned_at: @inside)

          assert_equal 1, rows_by_slug["k-selo"][:registered], "both conditions became true inside the window"
        end

        # Test 7 from the spec.
        test "an equal score is broken by who reached it first" do
          early = citizen(@grad, verified_at: @inside, assigned_at: @inside)
          report_for(early, at: @inside)
          late = citizen(@selo, verified_at: @inside + 1.day, assigned_at: @inside + 1.day)
          report_for(late, at: @inside + 1.day)

          slugs = Decidim::Bih::Race::Scorer.new(organization: @organization).rows.map { |r| r[:slug] }

          assert_equal %w(k-grad k-selo), slugs, "equal scores rank by reached_at ascending"
        end

        test "a komšiluk with no activity still appears with a zero score and no reached_at" do
          row = rows_by_slug["k-selo"]

          assert_equal 0, row[:score]
          assert_nil row[:reached_at]
        end

        test "a citizen without a komšiluk contributes to nobody" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(8), granted_at: @inside)
          report_for(user)

          assert_equal 0, rows_by_slug["k-grad"][:score]
          assert_equal 0, rows_by_slug["k-selo"][:score]
        end

        # Regression tests for the Critical finding: ranked_reports and
        # ranked_proposals must apply the SAME account-standing rule as
        # registrations (neither soft-deleted nor blocked), or an account an
        # admin blocks mid-campaign keeps inflating its neighbourhood forever
        # through content it created before the block.

        test "a blocked user's reports do not count toward the neighbourhood score" do
          blocked = citizen(@grad)
          report_for(blocked)
          report_for(blocked)
          blocked.update_columns(blocked: true, blocked_at: nil) # rubocop:disable Rails/SkipsModelValidations

          active = citizen(@grad)
          report_for(active)

          assert_equal 1, rows_by_slug["k-grad"][:reports], "only the still-active citizen's report should count"
        end

        test "an active user with a historic block timestamp remains eligible for all race activities" do
          user = citizen(@grad)
          report_for(user)
          proposal_for(user)
          user.update_columns(blocked: false, blocked_at: @inside - 1.day) # rubocop:disable Rails/SkipsModelValidations

          row = rows_by_slug.fetch("k-grad")
          assert_equal [1, 1, 1, 6], row.values_at(:registered, :reports, :proposals, :score)
          snapshot = Decidim::Bih::Race::SnapshotBuilder.new(organization: @organization).call
          assert_includes snapshot.fetch("electorate").map { |person| person.fetch("user_id") }, user.id
        end

        test "the blocked flag excludes all activities and electorate without a block timestamp" do
          user = citizen(@grad)
          report_for(user)
          proposal_for(user)
          user.update_columns(blocked: true, blocked_at: nil) # rubocop:disable Rails/SkipsModelValidations

          row = rows_by_slug.fetch("k-grad")
          assert_equal [0, 0, 0, 0], row.values_at(:registered, :reports, :proposals, :score)
          snapshot = Decidim::Bih::Race::SnapshotBuilder.new(organization: @organization).call
          assert_empty snapshot.fetch("electorate")
        end

        test "a non-citizen STI row cannot earn race points through legacy citizen associations" do
          user = citizen(@grad)
          report_for(user)
          proposal_for(user)
          # Raw SQL aggregation must enforce the same citizen scope as Decidim::User.
          user.update_columns(type: "Decidim::UserGroup") # rubocop:disable Rails/SkipsModelValidations

          row = rows_by_slug.fetch("k-grad")
          assert_equal [0, 0, 0, 0], row.values_at(:registered, :reports, :proposals, :score)
          snapshot = Decidim::Bih::Race::SnapshotBuilder.new(organization: @organization).call
          assert_empty snapshot.fetch("electorate")
          refute snapshot.fetch("items").any? { |item| item["kind"] == "registered" }
        end

        test "a soft-deleted user's reports do not count" do
          deleted = citizen(@grad)
          report_for(deleted)
          report_for(deleted)
          deleted.update_columns(deleted_at: @inside) # rubocop:disable Rails/SkipsModelValidations

          active = citizen(@grad)
          report_for(active)

          assert_equal 1, rows_by_slug["k-grad"][:reports], "only the still-active citizen's report should count"
        end

        test "a blocked user's proposals do not count toward the neighbourhood score" do
          blocked = citizen(@grad)
          proposal_for(blocked)
          blocked.update_columns(blocked: true, blocked_at: nil) # rubocop:disable Rails/SkipsModelValidations

          active = citizen(@grad)
          proposal_for(active)

          assert_equal 1, rows_by_slug["k-grad"][:proposals], "only the still-active citizen's proposal should count"
        end

        test "a soft-deleted user's proposals do not count" do
          deleted = citizen(@grad)
          proposal_for(deleted)
          deleted.update_columns(deleted_at: @inside) # rubocop:disable Rails/SkipsModelValidations

          active = citizen(@grad)
          proposal_for(active)

          assert_equal 1, rows_by_slug["k-grad"][:proposals], "only the still-active citizen's proposal should count"
        end
      end
    end
  end
end

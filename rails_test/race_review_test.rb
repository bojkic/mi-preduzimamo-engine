# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class RaceReviewTest < ActiveSupport::TestCase
        setup do
          travel_to Time.utc(2026, 9, 27, 10)
          @organization = create_organization
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          @a = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "race-a", zona: "grad", name: { sr: "A" })
          @b = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "race-b", zona: "selo", name: { sr: "B" })
          Decidim::Authorization.create!(user: @user, name: "sms", unique_id: SecureRandom.hex(8), granted_at: 1.day.ago)
          @profile = CitizenProfile.create!(organization: @organization, user: @user, komsiluk: @a, source: "dropdown", assigned_at: 1.day.ago)
          @review = Race::Review.new(@organization)
        end
        teardown { travel_back }

        def report(at: Time.current, **attrs)
          Report.create!(organization: @organization, author: @user, description: "Review test", status: "u_obradi",
                         review_state: "validated", created_at: at, **attrs)
        end

        def close_and_capture
          @review.baseline!(actor: @admin, reason: "Cutover preview")
          travel_to Time.utc(2026, 10, 14, 18, 0, 2)
          @review.capture!
        end

        def prepare_final
          ed = close_and_capture
          @review.settings!(actor: @admin, reason: "Approved operating dates", values: {
            review_closes_at: "2026-10-14T20:00:00+02:00", vote_starts_at: "2026-10-20T10:00:00+02:00",
            vote_ends_at: "2026-10-25T10:00:00+02:00", tie_procedure: "Admin reviewed procedure", zero_entry_procedure: "No award",
            project_owner: "Foundation", winners: { "selo" => "none" }
          })
          ed.reload
        end

        test "first qualifying area follows verification instead of an unverified early selection" do
          newcomer = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = CitizenProfile.create!(organization: @organization, user: newcomer, komsiluk: @a, source: "dropdown", assigned_at: 2.days.ago)
          @review.baseline!(actor: @admin, reason: "Cutover")
          assert_nil Race::Membership.find_by(decidim_user_id: newcomer.id)
          profile.assign_komsiluk!(@b, source: "dropdown")
          Decidim::Authorization.create!(user: newcomer, name: "sms", unique_id: SecureRandom.hex(8), granted_at: Time.current)
          assert_equal @b.id, Race::Membership.find_by!(decidim_user_id: newcomer.id).komsiluk_id
          profile.assign_komsiluk!(@a, source: "dropdown")
          assert_equal @b.id, Race::Membership.find_by!(decidim_user_id: newcomer.id).komsiluk_id
        end

        test "baseline preserves qualification and move does not transfer race credit" do
          report
          before = Race::Scorer.new(organization: @organization).rows
          @review.baseline!(actor: @admin, reason: "Baseline")
          assert_equal before, Race::Scorer.new(organization: @organization).rows
          stamp = @profile.assigned_at
          @profile.assign_komsiluk!(@a, source: "dropdown")
          assert_equal stamp, @profile.reload.assigned_at
          @profile.assign_komsiluk!(@b, source: "dropdown")
          assert_equal before, Race::Scorer.new(organization: @organization).rows
          member = Race::Edition.for(@organization).memberships.find_by!(decidim_user_id: @user.id)
          assert_equal "cutover_baseline", member.provenance
          assert_equal @a.id, member.komsiluk_id
        end

        test "electorate follows cutoff membership separately from contribution" do
          @review.baseline!(actor: @admin, reason: "Baseline")
          @profile.assign_komsiluk!(@b, source: "dropdown")
          travel_to Time.utc(2026,10,14,18,0,2)
          ed = @review.capture!
          assert_equal @b.id, ed.snapshot.fetch("electorate").find { |r| r["user_id"] == @user.id }["area"]
          assert_equal @a.id, ed.snapshot.fetch("items").find { |r| r["kind"] == "registered" }["area"]
        end

        test "snapshot retains overflow and late changes only enter through adjudication" do
          reports = 6.times.map { |i| report(at: Time.current - 1.hour + i.minutes, anonymous: i.even?) }
          ed = close_and_capture
          assert_equal 6, ed.snapshot.fetch("items").count { |r| r["kind"] == "report" }
          digest = ed.snapshot_digest
          reports.first.update!(status: "odbijeno")
          assert_equal 5, @review.preview.find { |r| r[:komsiluk_id] == @a.id }[:reports]
          @review.decide!(actor: @admin, reason: "Rejected after review", item_key: "report:#{reports.first.id}", include_item: false, expected_digest: digest)
          calculator = Race::Calculator.new(ed.snapshot, decisions: @review.decisions)
          assert_equal 5, calculator.rows.find { |r| r[:komsiluk_id] == @a.id }[:reports]
          assert_equal "counted", calculator.evidence.find { |r| r["key"] == "report:#{reports.last.id}" }["reason"]
          assert_equal digest, @review.capture!.snapshot_digest
          assert_raises(ActiveRecord::RecordInvalid) { ed.update!(snapshot: {}) }
        end

        test "a mistaken duplicate classification can be appealed without rewriting captured facts" do
          main = report(at: Time.current - 1.month)
          duplicate = report(duplicate_of: main)
          ed = close_and_capture
          key = "report:#{duplicate.id}"
          digest = ed.snapshot_digest
          captured = ed.snapshot.fetch("items").find { |item| item["key"] == key }.deep_dup
          assert_equal false, captured.fetch("eligible")
          assert_equal main.id, captured.dig("facts", "duplicate_of")
          assert_equal 0, @review.preview.find { |row| row[:komsiluk_id] == @a.id }[:reports]

          duplicate.update!(duplicate_of: nil)
          assert_equal 0, @review.preview.find { |row| row[:komsiluk_id] == @a.id }[:reports]
          reason = "Evidence reviewed: duplicate classification was mistaken"
          @review.decide!(actor: @admin, reason:, item_key: key, include_item: true, expected_digest: digest)
          assert_equal 1, @review.preview.find { |row| row[:komsiluk_id] == @a.id }[:reports]
          event = ed.events.where(kind: "adjudication", item_key: key).sole
          assert_equal true, event.data.fetch("include")
          assert_equal reason, event.data.fetch("reason")
          assert_equal digest, ed.reload.snapshot_digest
          assert_equal captured, ed.snapshot.fetch("items").find { |item| item["key"] == key }
        end

        test "capture and finalization refuse before cutoff and cannot be forced" do
          assert_raises(Race::Review::Invalid) { @review.capture! }
          assert_raises(Race::Review::Invalid) { @review.finalize!(actor: @admin, reason: "Early", expected_digest: "", expected_revision: 0) }
        end

        test "finalization consumes reviewed revision once and remains visible" do
          report
          ed = prepare_final
          revision = ed.events.maximum(:id)
          args = { actor: @admin, reason: "Final sign-off", expected_digest: ed.snapshot_digest, expected_revision: revision }
          assert_equal 2, @review.finalize!(**args)
          scores = Race::Standings.new(@organization).rows.map(&:score)
          assert_equal 0, @review.finalize!(**args)
          report
          assert_equal 0, Race::Standings.new(@organization).refresh!(force: true)
          assert_equal scores, Race::Standings.new(@organization).rows.map(&:score)
          assert Race::Visibility.visible?(@organization)
        end

        test "visibility is manual reversible tenant scoped and does not erase evidence" do
          report
          ed = prepare_final
          assert Race::Visibility.visible?(@organization)
          assert_raises(Decidim::ActionForbidden) { Race::Visibility.change!(@organization, visible: false, actor: @user, reason: "No permission") }
          Race::Visibility.change!(@organization, visible: false, actor: @admin, reason: "Archive")
          refute Race::Visibility.visible?(@organization)
          assert_equal ed.snapshot_digest, ed.reload.snapshot_digest
          Race::Visibility.change!(@organization, visible: true, actor: @admin, reason: "Restore")
          assert Race::Visibility.visible?(@organization)
        end

        test "membership change requires a matching impact preview" do
          report
          @review.baseline!(actor: @admin, reason: "Baseline")
          args = { actor: @admin, reason: "Proven correction", user_id: @user.id, area: @b.id, expected_area: @a.id }
          preview = @review.correct_membership!(**args, preview_only: true)
          assert_equal @a.id, Race::Edition.for(@organization).memberships.find_by!(decidim_user_id: @user.id).komsiluk_id
          assert_raises(Race::Review::Invalid) { @review.correct_membership!(**args, expected_preview: "stale") }
          @review.correct_membership!(**args, expected_preview: preview.fetch(:digest))
          assert_equal @b.id, Race::Edition.for(@organization).memberships.find_by!(decidim_user_id: @user.id).komsiluk_id
        end
      end
    end
  end
end

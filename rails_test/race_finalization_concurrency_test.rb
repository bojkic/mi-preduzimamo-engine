# frozen_string_literal: true
require "test_helper"
require "timeout"

module Decidim
  module Bih
    module RailsHarness
      class RaceFinalizationConcurrencyTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        setup do
          travel_to Time.utc(2026,10,15,10)
          @organization = create_organization
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @area = LocalArea.create!(organization: @organization, kind: "komsiluk", slug: "concurrent-race", zona: "grad", name: { sr: "Concurrent" })
          snapshot = { "areas" => [{ "id" => @area.id, "slug" => @area.slug, "zona" => "grad" }],
            "items" => [{ "key" => "registration:#{@admin.id}", "kind" => "registered", "source_id" => @admin.id,
                          "user_id" => @admin.id, "area" => @area.id, "at" => "2026-09-20T10:00:00Z", "eligible" => true, "facts" => {} }],
            "weights" => { "registered" => 1, "report" => 2, "proposal" => 3 }, "caps" => { "report" => 5, "proposal" => 3 }, "electorate" => [] }
          @edition = Race::Edition.create!(organization: @organization, key: Race::Edition::KEY,
            baseline_at: 2.days.ago, captured_at: 1.day.ago, snapshot:, snapshot_digest: Race::Edition.digest(snapshot), settings: {
              "review_closes_at" => "2026-10-15T08:00:00Z", "vote_starts_at" => "2026-10-20T08:00:00Z",
              "vote_ends_at" => "2026-10-25T08:00:00Z", "tie_procedure" => "Reviewed", "zero_entry_procedure" => "No award", "project_owner" => "Foundation" })
        end

        teardown do
          @threads&.each { |thread| thread.kill if thread.alive? }
          Race::Standing.where(decidim_organization_id: @organization&.id).delete_all
          Race::Event.where(edition_id: @edition&.id).delete_all
          Race::Membership.where(edition_id: @edition&.id).delete_all
          Race::Edition.where(id: @edition&.id).delete_all
          @admin&.destroy!
          @area&.destroy!
          # The generated host seeds protected legal pages for each tenant.
          # They are fixture data and deliberately cannot be destroyed by UI.
          @organization&.static_pages&.delete_all
          @organization&.destroy!
          travel_back
        end

        test "two connections with stale editions finalize once and cannot replace committed rows" do
          ready = Queue.new
          release = Queue.new
          results = Queue.new
          @threads = 2.times.map do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                stale = Race::Edition.find(@edition.id)
                review = Race::Review.new(@organization)
                review.define_singleton_method(:edition) { stale }
                ready << true
                release.pop
                results << review.finalize!(actor: @admin, reason: "Final", expected_digest: @edition.snapshot_digest, expected_revision: 0)
              end
            rescue StandardError => error
              results << error
            end
          end
          Timeout.timeout(10) { 2.times { ready.pop } }
          2.times { release << true }
          @threads.each { |thread| assert thread.join(10), "finalization lock did not finish" }
          actual = 2.times.map { results.pop }
          assert actual.all? { |value| value.is_a?(Integer) }, actual.inspect
          assert_equal [0,1], actual.sort, actual.inspect
          assert_equal 1, Race::Standing.where(organization: @organization, final: true).count
          assert_equal 1, Race::Event.where(edition: @edition, kind: "finalized").count
          assert_equal 1, Race::Standings.new(@organization).rows.first.score
        end
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class RaceAnalyticsExportTest < ActiveSupport::TestCase
        setup do
          # The 2026 race closed 14.10 20:00; scoring and refresh run only while it is open.
          travel_to Time.utc(2026, 10, 1, 10)
          @organization = create_organization
          Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-grad", zona: "grad", name: { "sr" => "Centar" }
          )
          Decidim::Bih::Race::Standings.new(@organization).refresh!(force: true)
          @summary = Decidim::Bih::Admin::AnalyticsSummary.new(organization: @organization)
        end

        test "race_standings is an exportable dataset" do
          assert_includes Decidim::Bih::Admin::AnalyticsSummary::DATASETS, "race_standings"
        end

        test "the csv carries the komšiluk figures and no personal data" do
          csv = @summary.csv_for("race_standings")

          assert_match "komsiluk_slug", csv
          assert_match "k-grad", csv
          assert_match "Centar", csv
          refute_match(/decidim_user_id|reporter_|email|phone/, csv)
        end

        test "the header contract excludes personal-data field names" do
          # csv_for only ever emits the headers listed here, so THIS is where the
          # privacy guarantee actually lives -- an output-level substring check
          # alone would pass vacuously for any header list that happens not to
          # contain PII-shaped words yet.
          #
          # "komsiluk_name" is deliberately allowed through: it is the
          # neighbourhood's public reference name (like "komsiluk_slug"), not a
          # citizen's name, so bare "name" is NOT on the denylist below -- only
          # terms that denote a person or a contact/identifying channel are.
          denylist = %w(user email phone reporter contact nickname reference token address description body message)
          headers = Decidim::Bih::Admin::AnalyticsSummary::HEADERS.fetch("race_standings")

          offending = headers.select { |header| denylist.any? { |term| header.include?(term) } }

          assert_empty offending, "race_standings headers must not expose personal data: #{offending}"
        end
      end
    end
  end
end

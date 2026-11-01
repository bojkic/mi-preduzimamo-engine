# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The grad/selo split is the thing that decides who competes against whom
      # for 3.000 KM, so it is proven against Postgres with real LocalArea rows.
      class ZoneClassifierTest < ActiveSupport::TestCase
        # A 10×10 frame at the origin.
        FRAME = {
          "type" => "Polygon",
          "coordinates" => [[[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0], [0.0, 0.0]]]
        }.freeze

        setup do
          @organization = create_organization
          Decidim::Bih::Setting.put(@organization, "geo", "city_frame", FRAME)
        end

        def komsiluk(slug, coordinates)
          Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug:,
            name: { "sr" => slug },
            boundary: { "type" => "Polygon", "coordinates" => [coordinates] }
          )
        end

        # Fully inside the frame.
        def inside_square(slug)
          komsiluk(slug, [[1.0, 1.0], [2.0, 1.0], [2.0, 2.0], [1.0, 2.0], [1.0, 1.0]])
        end

        # Fully outside the frame.
        def outside_square(slug)
          komsiluk(slug, [[20.0, 20.0], [21.0, 20.0], [21.0, 21.0], [20.0, 21.0], [20.0, 20.0]])
        end

        # Straddles x=10: 60% inside, 40% outside.
        def mostly_inside_square(slug)
          komsiluk(slug, [[9.4, 1.0], [10.4, 1.0], [10.4, 2.0], [9.4, 2.0], [9.4, 1.0]])
        end

        test "a komšiluk mostly inside the frame is grad, one outside is selo" do
          inside_square("k-in")
          outside_square("k-out")

          results = Decidim::Bih::Geo::ZoneClassifier.new(@organization).classify.index_by(&:slug)

          assert_equal "grad", results["k-in"].zona
          assert_in_delta 1.0, results["k-in"].ratio, 0.01
          assert_equal "selo", results["k-out"].zona
          assert_in_delta 0.0, results["k-out"].ratio, 0.01
        end

        test "the majority-of-area rule uses 50 percent, not the centroid" do
          mostly_inside_square("k-edge")

          result = Decidim::Bih::Geo::ZoneClassifier.new(@organization).classify.first

          assert_in_delta 0.6, result.ratio, 0.02
          assert_equal "grad", result.zona
          assert_predicate result, :borderline?, "0.6 sits on the 40–60% review band"
        end

        test "apply! writes zona and the computed ratio and is idempotent" do
          area = inside_square("k-in")
          classifier = Decidim::Bih::Geo::ZoneClassifier.new(@organization)

          classifier.apply!
          area.reload

          assert_equal "grad", area.zona
          assert_in_delta 1.0, area.metadata["zona_ratio"].to_f, 0.01

          classifier.apply!(force: true)

          assert_equal "grad", area.reload.zona
        end

        # Test 10 from the spec.
        test "every komšiluk ends up with exactly one zona and none is left blank" do
          inside_square("k-in")
          outside_square("k-out")
          mostly_inside_square("k-edge")

          Decidim::Bih::Geo::ZoneClassifier.new(@organization).apply!

          zones = Decidim::Bih::LocalArea.komsiluci.where(organization: @organization).pluck(:zona)

          assert_equal 3, zones.size
          assert_empty zones.select(&:blank?), "no komšiluk may be left without a zona"
          assert_empty zones - Decidim::Bih::LocalArea::ZONES
        end

        test "apply! refuses to overwrite a locked split unless forced" do
          inside_square("k-in")
          classifier = Decidim::Bih::Geo::ZoneClassifier.new(@organization)
          classifier.apply!
          classifier.lock!

          assert_predicate classifier, :locked?
          assert_raises(Decidim::Bih::Geo::ZoneClassifier::ZonesLockedError) { classifier.apply! }

          classifier.apply!(force: true)
        end

        test "lock! returns the ISO8601 string it stored, not a Time" do
          classifier = Decidim::Bih::Geo::ZoneClassifier.new(@organization)

          locked_at = classifier.lock!

          assert_kind_of String, locked_at
          assert_in_delta Time.current, Time.zone.parse(locked_at), 5.seconds
          assert_predicate classifier, :locked?
        end

        test "a missing city frame raises rather than silently marking everything selo" do
          Decidim::Bih::Setting.put(@organization, "geo", "city_frame", nil)
          inside_square("k-in")

          assert_raises(Decidim::Bih::Geo::ZoneClassifier::MissingCityFrameError) do
            Decidim::Bih::Geo::ZoneClassifier.new(@organization).classify
          end
        end

        test "a komšiluk without a boundary is reported rather than skipped" do
          Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-nil", name: { "sr" => "k-nil" }
          )

          result = Decidim::Bih::Geo::ZoneClassifier.new(@organization).classify.first

          assert_equal "selo", result.zona
          assert_in_delta 0.0, result.ratio, 0.001
        end
      end
    end
  end
end

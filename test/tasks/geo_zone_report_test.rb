# frozen_string_literal: true

require "test_helper"
require_relative "../../app/services/decidim/bih/geo/zone_report"

module Decidim
  module Bih
    module Geo
      class ZoneReportTest < Minitest::Test
        Result = Struct.new(:slug, :name, :ratio, :zona, keyword_init: true) do
          def borderline?
            (0.40..0.60).cover?(ratio)
          end
        end

        def results
          [
            Result.new(slug: "k-1", name: "Centar", ratio: 1.0, zona: "grad"),
            Result.new(slug: "k-2", name: "Pet jezera", ratio: 0.579, zona: "grad"),
            Result.new(slug: "k-3", name: "Novo Naselje", ratio: 0.448, zona: "selo"),
            Result.new(slug: "k-4", name: "Dvorovi", ratio: 0.0, zona: "selo")
          ]
        end

        def test_report_counts_each_league
          output = ZoneReport.render(results)

          assert_match(/GRAD:\s+2/, output)
          assert_match(/SELO:\s+2/, output)
          assert_match(/UKUPNO:\s+4/, output)
        end

        def test_report_lists_borderline_cases_separately
          output = ZoneReport.render(results)
          borderline_section = output.split("GRANIČNI").last

          assert_match(/Pet jezera/, borderline_section)
          assert_match(/Novo Naselje/, borderline_section)
          refute_match(/Centar/, borderline_section)
          refute_match(/Dvorovi/, borderline_section)
        end

        def test_report_renders_percentages_with_one_decimal
          output = ZoneReport.render(results)

          assert_match(/57\.9%/, output)
        end

        def test_report_says_so_when_there_are_no_borderline_cases
          clear = [Result.new(slug: "k-1", name: "Centar", ratio: 1.0, zona: "grad")]

          assert_match(/nema graničnih slučajeva/i, ZoneReport.render(clear))
        end
      end
    end
  end
end

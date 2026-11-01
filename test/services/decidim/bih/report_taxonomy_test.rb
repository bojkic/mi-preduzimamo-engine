# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/report_taxonomy"

module Decidim
  module Bih
    class ReportTaxonomyTest < Minitest::Test
      def test_vocabulary_keeps_the_original_values_types_and_order
        assert_equal [:rasvjeta, :saobracaj, :ekologija_otpad, :putevi, :komunalna_policija, :vodovod_kanalizacija, :grijanje, :ostalo], ReportTaxonomy::CATEGORIES
        assert_equal [:nizak, :normalan, :visok, :hitan], ReportTaxonomy::SEVERITIES
        assert_equal ReportTaxonomy::CATEGORIES, ReportTaxonomy::CATEGORY_DEPARTMENT.keys
        assert_equal ["Javna rasvjeta", "Saobraćaj i signalizacija", "Ekologija i otpad", "Putevi i infrastruktura",
                      "Komunalna policija", "Vodovod i kanalizacija", "Grijanje", "Ostalo"], ReportTaxonomy::CATEGORY_DEPARTMENT.values
        assert ReportTaxonomy::CATEGORIES.frozen?
        assert ReportTaxonomy::SEVERITIES.frozen?
        assert ReportTaxonomy::CATEGORY_DEPARTMENT.frozen?
      end
    end
  end
end

# frozen_string_literal: true

# Host-free bare-Minitest test: ActiveSupport's `assert_not` is not loaded here,
# so `refute` is the available negative assertion.
require "test_helper"
require "bigdecimal"
require "active_support/core_ext/object/blank"
require_relative "../../../../app/services/decidim/bih/impact_summary"

module Decidim
  module Bih
    # Unit coverage for the defensive decimal/value coercion helpers used by the
    # public impact dashboard. These guard against a donations provider (Odoo
    # mirror) returning nil or non-numeric garbage: every such case must degrade
    # to a zero/empty aggregate rather than raise, so the dashboard never crashes
    # on bad upstream data.
    #
    # The DB-backed paths of #donation_summary (which calls
    # Decidim::Bih.donations_provider and the Odoo result constant) are out of
    # scope for a host-free unit test; #donation_projects is exercised here
    # directly with a fake provider because it is pure given its arguments and
    # routes every numeric field through the same #decimal_value / #value_of
    # helpers as #donation_summary.
    class ImpactSummaryCoercionTest < Minitest::Test
      # A plain object (not a Struct) so a `count` reader does not collide with
      # Struct#count — this mirrors the real Odoo donation-totals object, whose
      # #total and #count are read by ImpactSummary via #value_of.
      class Totals
        attr_reader :total, :count

        def initialize(total:, count:)
          @total = total
          @count = count
        end
      end

      Project = Struct.new(:title, :totals, :donate_url, keyword_init: true)
      Provider = Struct.new(:project_mappings, keyword_init: true)

      def setup
        # Avoid #initialize so the test stays free of Rails/ActiveSupport time
        # helpers — only the pure coercion helpers are under test.
        @summary = Decidim::Bih::ImpactSummary.allocate
      end

      def test_decimal_value_parses_numeric_strings
        assert_equal BigDecimal("12.5"), decimal_value("12.5")
        assert_equal BigDecimal("0"), decimal_value("0")
      end

      def test_decimal_value_degrades_nil_to_zero
        assert_equal BigDecimal("0"), decimal_value(nil)
      end

      def test_decimal_value_degrades_garbage_string_to_zero
        assert_equal BigDecimal("0"), decimal_value("not-a-number")
        assert_equal BigDecimal("0"), decimal_value("")
      end

      def test_decimal_value_degrades_non_coercible_object_to_zero
        # An arbitrary object whose #to_s is non-numeric raises ArgumentError in
        # BigDecimal(); the helper must rescue it rather than propagate.
        assert_equal BigDecimal("0"), decimal_value(Object.new)
      end

      def test_value_of_reads_attribute_from_responder
        responder = Struct.new(:total, keyword_init: true).new(total: "9")

        assert_equal "9", value_of(responder, :total)
      end

      def test_value_of_reads_symbol_and_string_keys_from_hash
        assert_equal "5", value_of({ total: "5" }, :total)
        assert_equal "5", value_of({ "total" => "5" }, :total)
      end

      def test_value_of_returns_nil_for_unknown_key
        assert_nil value_of(Object.new, :missing)
        assert_nil value_of({}, :total)
      end

      def test_donation_projects_degrades_nil_totals_to_zero
        project = Project.new(
          title: "Park",
          totals: Totals.new(total: nil, count: nil),
          donate_url: "https://example.test/donate"
        )

        result = @summary.send(:donation_projects, Provider.new(project_mappings: [project]), "KM")

        assert_equal 1, result.length
        assert_equal BigDecimal("0"), result.first.total_amount
        assert_equal 0, result.first.orders_count
        assert_equal "KM", result.first.currency_label
      end

      def test_donation_projects_degrades_garbage_totals_to_zero
        project = Project.new(
          title: "Klupa",
          totals: Totals.new(total: "not-a-number", count: "3"),
          donate_url: nil
        )

        result = @summary.send(:donation_projects, Provider.new(project_mappings: [project]), "KM")

        assert_equal BigDecimal("0"), result.first.total_amount
        assert_equal 3, result.first.orders_count
      end

      def test_donation_projects_handles_provider_without_mappings
        provider = Object.new

        assert_equal [], @summary.send(:donation_projects, provider, "KM")
      end

      # The Donations struct's #unallocated? predicate drives whether the
      # reconciliation line renders on /uticaj; it must read the coerced
      # BigDecimal remainder, treating only a positive value as renderable.
      def test_donations_struct_unallocated_predicate
        assert Decidim::Bih::ImpactSummary::Donations.new(unallocated_amount: BigDecimal("20")).unallocated?
        refute Decidim::Bih::ImpactSummary::Donations.new(unallocated_amount: BigDecimal("0")).unallocated?
        refute Decidim::Bih::ImpactSummary::Donations.new(unallocated_amount: 0).unallocated?
        refute Decidim::Bih::ImpactSummary::Donations.new(unallocated_amount: nil).unallocated?
      end

      # End-to-end (host-free) check that #donation_summary reconciles: the grand
      # total above the sum of attributed per-project totals surfaces as the
      # unallocated remainder on the Donations struct. The provider hook and the
      # Odoo totals object are stubbed; #donation_projects stays real.
      def test_donation_summary_surfaces_unallocated_remainder
        provider = build_provider(
          total: "50",
          count: 1,
          projects: [
            stub_project("Park", "30"),
            stub_project("Klupa", "0")
          ]
        )

        summary = with_provider(provider) { @summary.send(:donation_summary) }

        assert_equal BigDecimal("50"), summary.total_amount
        assert_equal BigDecimal("20"), summary.unallocated_amount
        assert summary.unallocated?
        assert_equal [BigDecimal("30"), BigDecimal("0")], summary.projects.map(&:total_amount)
      end

      def test_donation_summary_has_no_remainder_when_projects_reconcile
        provider = build_provider(
          total: "50",
          count: 2,
          projects: [stub_project("Park", "20"), stub_project("Klupa", "30")]
        )

        summary = with_provider(provider) { @summary.send(:donation_summary) }

        assert_equal BigDecimal("0"), summary.unallocated_amount
        refute summary.unallocated?
      end

      private

      # A fake totals object (plain object, not a Struct, so #count does not
      # collide with Struct#count) mirroring the Odoo donation-totals shape.
      def build_totals(total:, count:)
        Totals.new(total:, count:).tap do |totals|
          totals.define_singleton_method(:currency) { "BAM" }
          totals.define_singleton_method(:as_of) { nil }
        end
      end

      def stub_project(title, total)
        Project.new(
          title:,
          totals: Totals.new(total:, count: 1),
          donate_url: nil
        )
      end

      def build_provider(total:, count:, projects:)
        totals = build_totals(total:, count:)
        provider = Object.new
        provider.define_singleton_method(:totals) { totals }
        provider.define_singleton_method(:currency_label) { "KM" }
        provider.define_singleton_method(:donate_url) { nil }
        provider.define_singleton_method(:project_mappings) { projects }
        provider
      end

      # Temporarily points Decidim::Bih.donations_provider at the fake provider
      # without booting a host. Requires the engine library so the constant and
      # the Odoo zero result are loadable.
      def with_provider(provider)
        require "decidim/bih"
        previous = Decidim::Bih.donations_provider
        Decidim::Bih.donations_provider = provider
        yield
      ensure
        Decidim::Bih.donations_provider = previous
      end

      def decimal_value(value)
        @summary.send(:decimal_value, value)
      end

      def value_of(object, key)
        @summary.send(:value_of, object, key)
      end
    end
  end
end
# rubocop:enable Rails/RefuteMethods

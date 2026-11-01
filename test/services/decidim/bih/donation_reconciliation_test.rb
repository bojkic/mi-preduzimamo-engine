# frozen_string_literal: true

# Host-free bare-Minitest test: ActiveSupport's `assert_not` is not loaded here,
# so `refute` is the available negative assertion.
require "test_helper"
require "bigdecimal"
require_relative "../../../../app/services/decidim/bih/donation_reconciliation"

module Decidim
  module Bih
    # Host-free unit coverage for the shared donation-display reconciliation math
    # used by BOTH /donacije (DonationsController) and /uticaj (ImpactSummary):
    #
    #     grand_total = Σ(attributed per-project totals) + unallocated
    #
    # The remainder is the unattributed donations (no Odoo campaign match). It
    # must clamp at >= 0 and degrade nil/garbage inputs to zero rather than raise.
    class DonationReconciliationTest < Minitest::Test
      Recon = Decidim::Bih::DonationReconciliation

      def test_decimal_value_parses_numeric_strings_and_passes_bigdecimal_through
        assert_equal BigDecimal("12.5"), Recon.decimal_value("12.5")
        assert_equal BigDecimal("0"), Recon.decimal_value("0")
        assert_equal BigDecimal("7"), Recon.decimal_value(BigDecimal("7"))
        assert_equal BigDecimal("3"), Recon.decimal_value(3)
      end

      def test_decimal_value_degrades_nil_and_garbage_to_zero
        assert_equal BigDecimal("0"), Recon.decimal_value(nil)
        assert_equal BigDecimal("0"), Recon.decimal_value("")
        assert_equal BigDecimal("0"), Recon.decimal_value("not-a-number")
        assert_equal BigDecimal("0"), Recon.decimal_value(Object.new)
      end

      def test_unallocated_is_grand_total_minus_attributed_sum
        # 50 total, one project attributed 30 -> 20 unallocated.
        amount = Recon.unallocated_amount(grand_total: 50, project_totals: [30])

        assert_equal BigDecimal("20"), amount
        assert Recon.unallocated?(grand_total: 50, project_totals: [30])
      end

      def test_no_remainder_when_attributed_sum_equals_grand_total
        amount = Recon.unallocated_amount(grand_total: 50, project_totals: [20, 30])

        assert_equal BigDecimal("0"), amount
        refute Recon.unallocated?(grand_total: 50, project_totals: [20, 30])
      end

      def test_full_grand_total_is_unallocated_when_every_project_is_zero
        # The reported bug: one confirmed donation, no campaign attribution, so
        # every project total is 0 and the whole grand total is unallocated.
        amount = Recon.unallocated_amount(grand_total: 50, project_totals: [0, 0, 0])

        assert_equal BigDecimal("50"), amount
        assert Recon.unallocated?(grand_total: 50, project_totals: [0, 0, 0])
      end

      def test_remainder_clamps_at_zero_when_attributed_exceeds_grand_total
        # Defensive: a stale/partial cache must never yield a negative line.
        amount = Recon.unallocated_amount(grand_total: 10, project_totals: [8, 8])

        assert_equal BigDecimal("0"), amount
        refute Recon.unallocated?(grand_total: 10, project_totals: [8, 8])
      end

      def test_remainder_is_null_safe_for_nil_and_garbage_inputs
        amount = Recon.unallocated_amount(
          grand_total: "40",
          project_totals: [nil, "10", "junk", BigDecimal("5")]
        )

        assert_equal BigDecimal("25"), amount
      end

      def test_remainder_handles_nil_grand_total_and_nil_project_list
        assert_equal BigDecimal("0"), Recon.unallocated_amount(grand_total: nil, project_totals: nil)
        assert_equal BigDecimal("0"), Recon.unallocated_amount(grand_total: nil, project_totals: [10])
      end
    end
  end
end
# rubocop:enable Rails/RefuteMethods

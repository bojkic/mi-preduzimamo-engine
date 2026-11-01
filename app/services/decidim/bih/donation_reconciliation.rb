# frozen_string_literal: true

require "bigdecimal"

module Decidim
  module Bih
    # Shared, host-free donation-display math for the public donation surfaces.
    #
    # WHY: the grand "total raised" figure is the sum of ALL confirmed Odoo
    # donation orders (no campaign filter), while each per-project total is only
    # the subset of orders whose Odoo campaign_id.name matches that project's UTM
    # slug. So Σ(per-project) <= grand total always; the remainder is donations
    # with no project attribution. Showing the grand total next to per-project
    # rows that don't add up to it (and per-project "0 KM" rows under a non-zero
    # total) is misleading, so both /donacije and /uticaj route through this
    # module to reconcile identically:
    #
    #     grand_total = Σ(attributed per-project totals) + unallocated
    #
    # The unallocated remainder is surfaced as an explicit "Opšti fond
    # (neraspoređeno)" line when positive; per-project amounts of 0 are hidden.
    #
    # NULL-SAFE: providers (the cached Odoo mirror) can return nil / non-numeric
    # garbage; every amount is coerced through #decimal_value so the math never
    # raises and degrades to BigDecimal("0").
    module DonationReconciliation
      module_function

      # Coerces an arbitrary value (nil, numeric, numeric String, BigDecimal,
      # or junk) into a BigDecimal, degrading anything non-coercible to zero.
      def decimal_value(value)
        return value if value.is_a?(BigDecimal)

        BigDecimal(value.to_s)
      rescue ArgumentError, TypeError
        BigDecimal("0")
      end

      # Unallocated remainder = grand_total − Σ(attributed per-project totals),
      # clamped at >= 0 defensively (per-project sums should never exceed the
      # grand total, but a stale/partial cache must never yield a negative line).
      #
      # +grand_total+ and each entry of +project_totals+ are coerced, so callers
      # may pass raw provider values.
      def unallocated_amount(grand_total:, project_totals:)
        total = decimal_value(grand_total)
        attributed = Array(project_totals).sum(BigDecimal("0")) { |amount| decimal_value(amount) }
        remainder = total - attributed
        remainder.negative? ? BigDecimal("0") : remainder
      end

      # True when there is a positive unallocated remainder worth rendering its
      # own reconciliation line.
      def unallocated?(grand_total:, project_totals:)
        unallocated_amount(grand_total:, project_totals:).positive?
      end
    end
  end
end

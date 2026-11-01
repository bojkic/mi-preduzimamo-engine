# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Lightweight measurement for the goodwill economy (R14) — a presentation
      # PORO (like Levels/Streaks), NOT a Decidim::Metric (that machinery is
      # component-scoped, needs nightly calculator jobs and a metrics table, and
      # is a poor fit for these ledger-derived figures). Computes a small hash of
      # headline figures for a rolling window, plus the equivalent figures for the
      # PRIOR window so the admin dashboard can show simple A/B-style deltas.
      #
      #   Metrics.new(organization).snapshot(window: 7.days)
      #   # => { current: {...}, previous: {...}, since:, window_days: }
      class Metrics
        DEFAULT_WINDOW = 7.days

        def initialize(organization)
          @organization = organization
        end

        # A two-window snapshot: the last +window+ vs the +window+ before it.
        def snapshot(window: DEFAULT_WINDOW)
          now = Time.current
          since = now - window
          prior_since = since - window

          {
            window_days: (window / 1.day).round,
            since:,
            current: figures(since, now),
            previous: figures(prior_since, since)
          }
        end

        # The figures hash for an explicit [from, to) window.
        def figures(from, to)
          {
            active_earners: active_earners(from, to),
            points_issued: points_issued(from, to),
            redemptions: redemptions(from, to),
            referrals: referrals(from, to),
            gifts: gifts(from, to),
            capped_actions: AwardAdmission.where(organization:, occurred_at: from...to, outcome: "capped").count,
            corroborations: Decidim::Bih::ReportCorroboration.where(organization:, created_at: from...to).count,
            pending_referrals_created: Referral.pending.where(organization:, created_at: from...to).count
          }
        end

        private

        attr_reader :organization

        # Distinct accounts credited by an "earn" in the window.
        def active_earners(from, to)
          Entry
            .joins(:ledger_transaction)
            .where(decidim_bih_goodwill_entries: { decidim_organization_id: organization.id })
            .where(decidim_bih_goodwill_transactions: { kind: "earn", created_at: from...to })
            .where("decidim_bih_goodwill_entries.amount > 0")
            .distinct
            .count(:decidim_bih_goodwill_account_id)
        end

        # Total positive "earn" credits issued in the window.
        def points_issued(from, to)
          Entry
            .joins(:ledger_transaction)
            .where(decidim_bih_goodwill_entries: { decidim_organization_id: organization.id })
            .where(decidim_bih_goodwill_transactions: { kind: "earn", created_at: from...to })
            .where("decidim_bih_goodwill_entries.amount > 0")
            .sum("decidim_bih_goodwill_entries.amount")
        end

        def redemptions(from, to)
          txn_count("redeem", from, to)
        end

        def gifts(from, to)
          txn_count("gift", from, to)
        end

        def referrals(from, to)
          Referral
            .where(organization:, status: "rewarded")
            .where(rewarded_at: from...to)
            .count
        end

        def txn_count(kind, from, to)
          Transaction
            .where(organization:, kind:, created_at: from...to)
            .count
        end
      end
    end
  end
end

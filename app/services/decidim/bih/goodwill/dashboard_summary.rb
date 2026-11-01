# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Read model behind the admin "Goodwill economy" dashboard. Owns everything
      # the GoodwillController#index used to compute inline: the cached headline
      # summary (total issued, top earners, metrics, anomalies — keyed so cache
      # behaviour is byte-identical), the bounded admin queues with N-of-M
      # counts, the recent-transaction lists, and the stale-report figures.
      #
      #   DashboardSummary.new(organization).to_h
      #   # => { total_issued:, top_earners:, metrics:, anomalies:,
      #   #      recent_redemptions:, recent_transactions:,
      #   #      pending_match_requests_total:, pending_match_requests:, ... }
      #
      # The controller assigns each key straight onto a matching @ivar, so the
      # dashboard view reads exactly the same data structures as before.
      class DashboardSummary
        # Recent-transaction list length and pending-queue cap. Kept here as the
        # owner of these reads; the controller exposes the same constants for any
        # callers that still reference them.
        RECENT_LIMIT = 15
        QUEUE_LIMIT = 50
        DASHBOARD_CACHE_TTL = 2.minutes

        def initialize(organization, reward_fulfillment_filters: {}, history_page: nil, history_kind: nil)
          @organization = organization
          @history_page = history_page
          @history_kind = history_kind.to_s.presence_in(Transaction::KINDS)
          @reward_fulfillment_filters = reward_fulfillment_filters
        end

        # The full data structure GoodwillController#index renders. Mirrors the
        # previous ivar assignments key-for-key.
        def to_h
          summary = cached_summary

          {
            total_issued: summary.fetch(:total_issued),
            top_earners: summary.fetch(:top_earners),
            metrics: summary.fetch(:metrics),
            anomalies: summary.fetch(:anomalies),
            anomaly_scan: summary.fetch(:anomaly_scan),
            monitoring: summary.fetch(:monitoring),
            recent_redemptions: recent_transactions(%w(redeem)),
            recent_transactions: recent_transactions(Transaction::KINDS)
          }.merge(queues).merge(
            stale_reports_count:,
            oldest_stale_report:
          )
        end

        private

        attr_reader :organization, :reward_fulfillment_filters

        # Queues with N-of-M counts (Round 11, Item 5): every bounded queue
        # surfaces the total so admins know when QUEUE_LIMIT clips the list.
        def queues
          base_match = MatchRequest.pending.where(organization:)
          base_match_payouts = MatchRequest.approved.unpaid.where(organization:)
          base_paid_matches = MatchRequest.approved.paid.where(organization:)
          base_org_spending = OrganizationSpendingRequest.pending.where(organization:)
          base_fulfillments = reward_fulfillment_scope
          base_failures = Decidim::Bih::Report
                          .forwarding_attention.where(organization:)

          {
            pending_match_requests_total: base_match.count,
            pending_match_requests: base_match.includes(:owner)
                                              .order(:created_at, :id).limit(QUEUE_LIMIT),

            approved_match_payouts_total: base_match_payouts.count,
            approved_match_payouts: base_match_payouts
              .includes(:owner, :decided_by)
              .order(:decided_at, :id)
              .limit(QUEUE_LIMIT),

            recent_paid_match_requests_total: base_paid_matches.count,
            recent_paid_match_requests: base_paid_matches
              .includes(:owner, :payout_recorded_by)
              .order(payout_recorded_at: :desc, id: :desc)
              .limit(QUEUE_LIMIT),

            pending_organization_spending_total: base_org_spending.count,
            pending_organization_spending: base_org_spending
              .includes(:source_partner_profile, :target_partner_profile, :requested_by)
              .order(:created_at, :id)
              .limit(QUEUE_LIMIT),

            pending_reward_fulfillments_total: base_fulfillments.count,
            pending_reward_fulfillments: base_fulfillments
              .includes(:user, :handled_by, :ledger_transaction, events: :actor)
              .order(:created_at, :id).limit(QUEUE_LIMIT),

            report_forwarding_failures_total: base_failures.count,
            report_forwarding_failures: base_failures
              .order(forwarding_failed_at: :desc, id: :desc)
              .limit(QUEUE_LIMIT)
          }
        end

        def reward_fulfillment_scope
          scope = RewardFulfillment.where(organization:)
          status = reward_fulfillment_filters[:status].presence || "open"
          scope = case status
                  when "all"
                    scope
                  when "open"
                    scope.open
                  else
                    scope.where(status:)
                  end

          reward_key = reward_fulfillment_filters[:reward_key].presence
          scope = scope.where(reward_key:) if reward_key
          scope
        end

        def cached_summary
          Rails.cache.fetch(cache_key, expires_in: DASHBOARD_CACHE_TTL) do
            scan = AnomalyScan.new(organization).report
            {
              total_issued: total_points_issued,
              top_earners:,
              metrics: Metrics.new(organization).snapshot,
              anomalies: anomaly_flags(scan[:flags]),
              anomaly_scan: scan.except(:flags),
              monitoring: MonitoringSnapshot.new(organization).call
            }
          end
        end

        def cache_key
          [
            "decidim-bih",
            "admin-goodwill-v2",
            organization.id,
            I18n.locale,
            ledger_version,
            referral_version,
            group_membership_version,
            Decidim::Bih::PartnerMembership.where(organization:).maximum(:updated_at)&.utc&.iso8601(6),
            AwardAdmission.where(organization:).maximum(:id),
            CreditCorrection.where(organization:).maximum(:id)
          ].join("/")
        end

        def ledger_version
          relation = Transaction.where(organization:)
          latest = relation.maximum(:created_at)&.utc.to_i

          "#{relation.count}-#{latest}"
        end

        def referral_version
          relation = Referral.rewarded.where(organization:)
          latest = relation.maximum(:updated_at)&.utc.to_i

          "#{relation.count}-#{latest}"
        end

        def group_membership_version
          membership = GroupMembership
          return "unavailable" unless membership.available?

          latest = membership.admins.maximum(:updated_at)&.utc.to_i

          "#{membership.admins.count}-#{latest}"
        end

        # All points ever issued into circulation = sum of positive credits on
        # "earn" transactions for this org (mirrors the contribution definition).
        def total_points_issued
          Entry
            .joins(:ledger_transaction)
            .where(decidim_bih_goodwill_entries: { decidim_organization_id: organization.id })
            .where(decidim_bih_goodwill_transactions: { kind: "earn" })
            .where("decidim_bih_goodwill_entries.amount > 0")
            .sum("decidim_bih_goodwill_entries.amount")
        end

        def top_earners
          Account
            .contribution_leaderboard(organization, limit: 10)
            .includes(:owner)
            .filter_map do |account|
              owner = account.owner
              next if owner.nil?

              {
                account_id: account.id,
                owner_id: owner.id,
                owner_name: Decidim::Bih::Goodwill::PartnerOwner.display_name(owner),
                score: account.contribution_score.to_i
              }
            end
        end

        def anomaly_flags(flags)
          flags.map do |flag|
              user = flag[:user]

              {
                type: flag[:type].to_s,
                severity: flag[:severity].to_s,
                user_id: user&.id,
                user_name: user_display_name(user),
                detail: flag[:detail].to_s,
                count: flag[:count]
              }
            end
        end

        def user_display_name(user)
          return nil if user.nil?

          Decidim::Bih::Goodwill::PartnerOwner.display_name(user)
        end

        def recent_transactions(kinds)
          relation = Transaction.where(organization:, kind: kinds)
          relation = relation.where(kind: @history_kind) if @history_kind && kinds == Transaction::KINDS
          relation.order(created_at: :desc, id: :desc).page(@history_page).per(RECENT_LIMIT)
        end

        def stale_reports_count
          Decidim::Bih::Report
            .stale
            .where(organization:)
            .count
        end

        def oldest_stale_report
          Decidim::Bih::Report
            .stale
            .where(organization:)
            .order(:created_at)
            .first
        end
      end
    end
  end
end

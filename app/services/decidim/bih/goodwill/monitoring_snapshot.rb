# frozen_string_literal: true

require "set"

module Decidim
  module Bih
    module Goodwill
      # Private operational aggregates. No nicknames, contacts or automatic
      # penalties. Persisted source admission keys make webhook retries one act.
      class MonitoringSnapshot
        LIMIT = 5_000

        def initialize(organization, since: 30.days.ago)
          @organization, @since = organization, since
        end

        def call
          referrals = Referral.where(organization: @organization)
          admissions = AwardAdmission.where(organization: @organization, occurred_at: @since..)
          edges = referrals.order(:created_at, :id).limit(LIMIT + 1).pluck(:referrer_id, :invitee_id)
          truncated = edges.length > LIMIT
          edges = edges.first(LIMIT)
          # An invitee has one parent. Bound traversal on malformed cycles.
          parents = edges.to_h { |referrer, invitee| [invitee, referrer] }
          depth = parents.keys.map do |user_id|
            visited = Set.new
            node = user_id
            while parents[node] && visited.add?(node) && visited.length < 100
              node = parents[node]
            end
            truncated ||= parents[node].present?
            visited.length
          end.max.to_i
          reports = Decidim::Bih::Report.where(organization: @organization, created_at: @since..)
          latest_action = "(SELECT metadata->>'action' FROM decidim_bih_report_events e WHERE e.decidim_bih_report_id = decidim_bih_reports.id AND e.event_type = 'case_decision_applied' ORDER BY e.id DESC LIMIT 1)"
          rejected = reports.where(status: "odbijeno").where("duplicate_of_report_id IS NULL OR #{latest_action} = 'reject'")
          duplicates = reports.where.not(duplicate_of_report_id: nil).where("status <> 'odbijeno' OR #{latest_action} IS DISTINCT FROM 'reject'")
          current_area_counts = Decidim::Bih::CitizenProfile.where(organization: @organization,
            decidim_user_id: referrals.select(:invitee_id)).where.not(komsiluk_id: nil).group(:komsiluk_id).count
          {
            status: truncated ? "partial" : "complete", computed_at: Time.current, since: @since,
            admissions_since: AwardAdmission.where(organization: @organization).minimum(:created_at),
            admission_outcomes: admissions.group(:action, :period, :outcome).count,
            at_cap_accounts: admissions.where(outcome: "capped").distinct.count(:account_id),
            corroboration_actors: Decidim::Bih::ReportCorroboration.where(organization: @organization, created_at: @since..).distinct.count(:decidim_user_id),
            rejected_reports: rejected.count,
            duplicate_reports: duplicates.count,
            largest_current_area_referral_cohort: current_area_counts.values.max.to_i,
            referral_counts: referrals.group(:status).count,
            referral_pending_reasons: referrals.pending.group(:pending_reason).count,
            largest_referrer_cohort: referrals.group(:referrer_id).count.values.max.to_i,
            observed_referral_depth: depth,
            referral_graph_truncated: truncated,
            pending_recoveries: CreditSettlement.admin_pending.joins(:credit_correction)
              .where(decidim_bih_goodwill_credit_corrections: { decidim_organization_id: @organization.id }).count +
              VolunteerBonusCommitment.where(organization: @organization, status: "admin_pending").count
          }
        rescue StandardError => e
          Rails.logger.error("[Goodwill] monitoring status=failed error=#{e.class}")
          { status: "failed", computed_at: Time.current, since: @since }
        end
      end
    end
  end
end

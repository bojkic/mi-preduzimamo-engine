# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Read-only fraud/anomaly monitoring (R10) over the immutable ledger,
      # WITHOUT any IP/device data. Surfaces SUSPICIOUS PATTERNS as advisory flags
      # for an admin to review — it never auto-punishes and never writes.
      #
      # Three detectors:
      #   (a) earn velocity   — a user with an abnormally high number of distinct
      #                         earn awards in a single day (point-farming signal).
      #   (b) self-dealing    — a gift→regrant loop between the SAME user and a
      #                         group they administer (laundering recognition back
      #                         to themselves through a group wallet).
      #   (c) referral cluster — many rewarded referrals from one referrer inside a
      #                         short window (Sybil/invite-farm signal).
      #
      #   Decidim::Bih::Goodwill::AnomalyScan.new(organization).flags
      #   # => [ { type:, severity:, user:, detail:, count: }, ... ]
      class AnomalyScan
        # Tunables (deliberately conservative; advisory only).
        EARN_VELOCITY_PER_DAY = 30 # distinct earn awards in one day
        REFERRAL_CLUSTER_COUNT = 10 # rewarded referrals
        REFERRAL_CLUSTER_WINDOW = 1.day
        LOOKBACK = 30.days

        def initialize(organization, lookback: LOOKBACK)
          @organization = organization
          @since = Time.current - lookback
        end

        # All flags, highest severity first. Each is a plain Hash so the admin
        # view can render it without coupling to model internals. Wrapped so a
        # detector failure degrades to "no flag from that detector" rather than
        # 500-ing the dashboard.
        def flags
          report.fetch(:flags)
        end

        def report
          result = { flags: [], detectors: {}, computed_at: Time.current, since: }
          %i(earn_velocity self_dealing referral_cluster point_velocity report_rejection cap_usage corroboration).each do |detector|
            begin
              result[:flags].concat(public_send_detector(detector))
              result[:detectors][detector] = "complete"
            rescue StandardError => e
              result[:detectors][detector] = "failed"
              Rails.logger.error("[Goodwill] anomaly detector=#{detector} status=failed error=#{e.class}")
            end
          end
          completed = result[:detectors].values.count("complete")
          result[:status] = completed == result[:detectors].size ? "complete" : (completed.zero? ? "failed" : "partial")
          result[:flags].sort_by! { |flag| -severity_rank(flag[:severity]) }
          result
        end

        private

        attr_reader :organization, :since

        SEVERITY_ORDER = { "high" => 3, "medium" => 2, "low" => 1 }.freeze

        def public_send_detector(detector)
          send("#{detector}_flags")
        end

        def point_velocity_flags
          totals = Entry.joins(:ledger_transaction).where(organization:)
                        .where(decidim_bih_goodwill_transactions: { kind: "earn", created_at: since.. })
                        .where("decidim_bih_goodwill_entries.amount > 0")
                        .group(:decidim_bih_goodwill_account_id,
                               Arel.sql("DATE_TRUNC('day', (decidim_bih_goodwill_transactions.created_at AT TIME ZONE 'UTC') AT TIME ZONE 'Europe/Sarajevo')::date"))
                        .having("SUM(decidim_bih_goodwill_entries.amount) > 1000")
                        .sum("decidim_bih_goodwill_entries.amount")
          totals.filter_map do |(account_id, day), amount|
            user = Account.find_by(id: account_id, organization:)&.owner
            next unless user

            { type: "point_velocity", severity: "low", user:, count: amount,
              detail: I18n.t("decidim.bih.admin.goodwill.index.anomalies.point_velocity_detail", count: amount, date: day) }
          end
        end

        def report_rejection_flags
          reports = Decidim::Bih::Report.where(organization:, created_at: since..).where.not(decidim_user_id: nil)
          reports.group(:decidim_user_id).having("COUNT(*) >= 5").count.filter_map do |author_id, total|
            rejected = reports.where(decidim_user_id: author_id, status: "odbijeno")
                              .where("duplicate_of_report_id IS NULL OR (SELECT metadata->>'action' FROM decidim_bih_report_events e WHERE e.decidim_bih_report_id = decidim_bih_reports.id AND e.event_type = 'case_decision_applied' ORDER BY e.id DESC LIMIT 1) = 'reject'")
                              .count
            next unless rejected * 2 >= total

            user = Decidim::User.find_by(id: author_id, organization:)
            next unless user

            { type: "report_rejection", severity: "low", user:, count: rejected,
              detail: I18n.t("decidim.bih.admin.goodwill.index.anomalies.report_rejection_detail", count: rejected, total:) }
          end
        end

        def cap_usage_flags
          AwardAdmission.where(organization:, action: %w(report proposal report_corroboration), occurred_at: since.., outcome: "capped")
                        .group(:account_id, :action, :period).count.filter_map do |(account_id, action, period), count|
            user = Account.find_by(id: account_id, organization:)&.owner
            next unless user

            { type: "cap_usage", severity: "low", user:, count:,
              detail: I18n.t("decidim.bih.admin.goodwill.index.anomalies.cap_usage_detail", count:, action:, period:) }
          end
        end

        def corroboration_flags
          Decidim::Bih::ReportCorroboration.where(organization:, created_at: since..)
                    .group(:decidim_user_id).having("COUNT(DISTINCT report_id) >= 10").count.filter_map do |user_id, count|
            user = Decidim::User.find_by(id: user_id, organization:)
            next unless user

            { type: "corroboration", severity: "low", user:, count:,
              detail: I18n.t("decidim.bih.admin.goodwill.index.anomalies.corroboration_detail", count:) }
          end
        end

        def severity_rank(sev)
          SEVERITY_ORDER.fetch(sev.to_s, 0)
        end

        # (a) Abnormal daily earn velocity: group earn transactions by (account,
        # day) and flag accounts exceeding the per-day threshold on any day.
        def earn_velocity_flags
          rows = Entry
                 .joins(:ledger_transaction)
                 .where(decidim_bih_goodwill_entries: { decidim_organization_id: organization.id })
                 .where(decidim_bih_goodwill_transactions: { kind: "earn", created_at: since.. })
                 .where("decidim_bih_goodwill_entries.amount > 0")
                 .group(
                   "decidim_bih_goodwill_entries.decidim_bih_goodwill_account_id",
                   Arel.sql("DATE_TRUNC('day', (decidim_bih_goodwill_transactions.created_at AT TIME ZONE 'UTC') AT TIME ZONE 'Europe/Sarajevo')::date")
                 )
                 .having("COUNT(*) > ?", EARN_VELOCITY_PER_DAY)
                 .count

          # rows => { [account_id, date] => count }
          rows.filter_map do |(account_id, day), count|
            account = Account.find_by(id: account_id)
            owner = account&.owner
            next if owner.nil?

            {
              type: "earn_velocity",
              severity: count > EARN_VELOCITY_PER_DAY * 2 ? "high" : "medium",
              user: owner,
              detail: I18n.t(
                "decidim.bih.admin.goodwill.index.anomalies.earn_velocity_detail",
                count:, date: day
              ),
              count:
            }
          end
        end

        # (b) Self-dealing gift↔regrant loops: find users who both GIFTED to a
        # group they administer AND received a REGRANT from that same group. The
        # group memberships table identifies admin relationships; the ledger gives
        # the directed transfers. Degrades to [] if the legacy memberships table
        # is gone.
        def self_dealing_flags
          pairs = Decidim::Bih::PartnerMembership.accepted.where(organization:, role: Decidim::Bih::PartnerMembership::FINANCE_ROLES)
                   .includes(:user, :partner_profile).map { |membership| [membership.user, PartnerOwner.owner_for(membership.partner_profile)] }
          if GroupMembership.available?
            GroupMembership.admins.pluck(:decidim_user_id, :decidim_user_group_id).each do |user_id, group_id|
              user = Decidim::User.find_by(id: user_id, organization:)
              group = Decidim::User.find_by(id: group_id, organization:)
              pairs << [user, group] if user && group
            end
          end
          pairs.uniq { |user, owner| [user.id, owner.class.base_class.name, owner.id] }.filter_map do |user, owner|
            next unless transfer_exists?(kind: "gift", from: user, to: owner) && transfer_exists?(kind: "regrant", from: owner, to: user)

            { type: "self_dealing", severity: "low", user:,
              detail: I18n.t("decidim.bih.admin.goodwill.index.anomalies.self_dealing_detail", group: PartnerOwner.display_name(owner)), count: nil }
          end
        end

        # (c) Referral clusters: a referrer with many rewarded referrals inside a
        # short window. Groups rewarded referrals by referrer and day; flags those
        # exceeding the threshold.
        def referral_cluster_flags
          rows = Referral
                 .where(organization:, status: "rewarded")
                 .where(rewarded_at: since..)
                 .group(
                   :referrer_id,
                   Arel.sql("DATE_TRUNC('day', (rewarded_at AT TIME ZONE 'UTC') AT TIME ZONE 'Europe/Sarajevo')::date")
                 )
                 .having("COUNT(*) >= ?", REFERRAL_CLUSTER_COUNT)
                 .count

          rows.filter_map do |(referrer_id, day), count|
            referrer = Decidim::User.find_by(id: referrer_id, organization:)
            next if referrer.nil?

            {
              type: "referral_cluster",
              severity: count >= REFERRAL_CLUSTER_COUNT * 2 ? "high" : "medium",
              user: referrer,
              detail: I18n.t(
                "decidim.bih.admin.goodwill.index.anomalies.referral_cluster_detail",
                count:, date: day
              ),
              count:
            }
          end
        end

        # Does a transfer of +kind+ from +from+'s account to +to+'s account exist
        # in the lookback window? A transfer books a NEGATIVE entry on the sender's
        # account and a POSITIVE one on the receiver's, in the same transaction.
        def transfer_exists?(kind:, from:, to:)
          from_account = account_id_for(from)
          to_account = account_id_for(to)
          return false if from_account.nil? || to_account.nil?

          Transaction
            .where(organization:, kind:, created_at: since..)
            .where(
              id: Entry.where(decidim_bih_goodwill_account_id: from_account)
                       .where("amount < 0").select(:decidim_bih_goodwill_transaction_id)
            )
            .exists?(
              id: Entry.where(decidim_bih_goodwill_account_id: to_account)
                       .where("amount > 0").select(:decidim_bih_goodwill_transaction_id)
            )
        end

        def account_id_for(owner)
          Account
            .where(
              organization:,
              owner_type: owner.class.base_class.name,
              owner_id: owner.id,
              kind: "user"
            )
            .pick(:id)
        end
      end
    end
  end
end

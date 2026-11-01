# frozen_string_literal: true

require "bigdecimal"
require_relative "donation_reconciliation"

module Decidim
  module Bih
    # Public, PII-safe aggregate read model for the citizen impact dashboard.
    #
    # Privacy contract: this service returns only counts, sums, localized area
    # names and project titles already used publicly. It never exposes report
    # descriptions, contacts, coordinates, donor identities, volunteer free text,
    # Komšiluk post titles/bodies, Viber identifiers, or user names.
    class ImpactSummary
      LOOKBACK_DAYS = 30
      AREA_LIMIT = 8
      PROJECT_LIMIT = 6
      MIN_PUBLIC_CELL = 3

      Result = Struct.new(
        :generated_at,
        :lookback_days,
        :reports,
        :donations,
        :goodwill,
        :volunteering,
        :komsiluk,
        :trend_metrics,
        :area_activity,
        keyword_init: true
      )
      Reports = Struct.new(
        :total,
        :resolved,
        :open,
        :recent,
        :located,
        :local_area_count,
        :status_counts,
        :category_counts,
        keyword_init: true
      )
      Donations = Struct.new(
        :total_amount,
        :orders_count,
        :currency_label,
        :as_of,
        :donate_url,
        :projects,
        :unallocated_amount,
        keyword_init: true
      ) do
        # True when there is a positive unallocated remainder (grand total above
        # the sum of attributed per-project totals) to surface as its own line.
        # Null-safe: a nil/garbage amount coerces to zero (not renderable).
        def unallocated?
          Decidim::Bih::DonationReconciliation.decimal_value(unallocated_amount).positive?
        end
      end
      DonationProject = Struct.new(
        :title,
        :total_amount,
        :orders_count,
        :currency_label,
        :donate_url,
        keyword_init: true
      )
      Goodwill = Struct.new(
        :points_issued,
        :earn_transactions,
        :active_earners,
        :recent_points,
        :reward_redemptions,
        keyword_init: true
      )
      Volunteering = Struct.new(
        :approved_hours,
        :approved_logs,
        :active_opportunities,
        :upcoming_opportunities,
        :volunteers,
        keyword_init: true
      )
      Komsiluk = Struct.new(
        :posts,
        :visible,
        :closed,
        :hidden,
        :expired,
        :recent,
        :active_komsiluci,
        :category_counts,
        keyword_init: true
      )
      AreaActivity = Struct.new(
        :slug,
        :name,
        :reports,
        :resolved_reports,
        :komsiluk_posts,
        :total,
        keyword_init: true
      ) do
        def public_reports
          public_cell(reports)
        end

        def public_resolved_reports
          public_cell(resolved_reports)
        end

        def public_komsiluk_posts
          public_cell(komsiluk_posts)
        end

        private

        def public_cell(value)
          value.to_i >= Decidim::Bih::ImpactSummary::MIN_PUBLIC_CELL ? value.to_i : nil
        end
      end
      TrendMetric = Struct.new(
        :key,
        :current,
        :previous,
        :delta,
        keyword_init: true
      ) do
        def direction
          return "up" if delta.to_i.positive?
          return "down" if delta.to_i.negative?

          "steady"
        end
      end

      def initialize(organization:, since: nil, area_limit: AREA_LIMIT)
        @organization = organization
        @since = since || LOOKBACK_DAYS.days.ago
        @area_limit = area_limit
      end

      def call
        Result.new(
          generated_at: now,
          lookback_days:,
          reports: report_summary,
          donations: donation_summary,
          goodwill: goodwill_summary,
          volunteering: volunteering_summary,
          komsiluk: komsiluk_summary,
          trend_metrics:,
          area_activity:
        )
      end

      private

      attr_reader :organization, :since, :area_limit

      def report_scope
        Decidim::Bih::Report.where(organization:)
      end

      def report_summary
        scope = report_scope
        resolved = scope.where(duplicate_of_report_id: nil).resolved.count

        Reports.new(
          total: scope.count,
          resolved:,
          open: scope.where(duplicate_of_report_id: nil).where.not(status: Decidim::Bih::Report::TERMINAL_STATUSES).count,
          recent: scope.where(created_at: current_period).count,
          located: scope.where.not(latitude: nil).where.not(longitude: nil).count,
          local_area_count: scope.where.not(mz_slug: [nil, ""]).distinct.count(:mz_slug),
          status_counts: ReportStatusPresenter.status_counts(scope),
          category_counts: scope.where.not(category: [nil, ""]).group(:category).count
        )
      end

      def donation_summary
        provider = Decidim::Bih.donations_provider_for(organization:)
        totals = provider&.totals || Decidim::Bih::Odoo::DonationTotals::Result.zero
        currency_label = value_of(provider, :currency_label).presence || value_of(totals, :currency).presence || "KM"

        grand_total = decimal_value(value_of(totals, :total))
        projects = donation_projects(provider, currency_label)
        unallocated = Decidim::Bih::DonationReconciliation.unallocated_amount(
          grand_total:,
          project_totals: projects.map(&:total_amount)
        )

        Donations.new(
          total_amount: grand_total,
          orders_count: value_of(totals, :count).to_i,
          currency_label:,
          as_of: value_of(totals, :as_of),
          donate_url: value_of(provider, :donate_url),
          projects:,
          unallocated_amount: unallocated
        )
      end

      def donation_projects(provider, currency_label)
        return [] unless provider.respond_to?(:project_mappings)

        Array(provider_project_mappings(provider)).first(PROJECT_LIMIT).map do |project|
          totals = value_of(project, :totals)

          DonationProject.new(
            title: value_of(project, :title).to_s,
            total_amount: decimal_value(value_of(totals, :total)),
            orders_count: value_of(totals, :count).to_i,
            currency_label:,
            donate_url: value_of(project, :donate_url)
          )
        end
      end

      def provider_project_mappings(provider)
        provider.project_mappings(organization:)
      rescue ArgumentError
        provider.project_mappings
      end

      def goodwill_summary
        earnings = goodwill_earn_entries

        Goodwill.new(
          points_issued: earnings.sum("decidim_bih_goodwill_entries.amount").to_i,
          earn_transactions: Decidim::Bih::Goodwill::Transaction.earnings.where(organization:).count,
          active_earners: earnings.distinct.count(:decidim_bih_goodwill_account_id),
          recent_points: earnings
            .where(decidim_bih_goodwill_transactions: { created_at: current_period })
            .sum("decidim_bih_goodwill_entries.amount").to_i,
          reward_redemptions: Decidim::Bih::Goodwill::Transaction.where(organization:, kind: "redeem").count
        )
      end

      def goodwill_earn_entries
        Decidim::Bih::Goodwill::Entry
          .joins(:ledger_transaction)
          .where(decidim_bih_goodwill_entries: { decidim_organization_id: organization.id })
          .where(decidim_bih_goodwill_transactions: { kind: "earn" })
          .where("decidim_bih_goodwill_entries.amount > 0")
      end

      def volunteering_summary
        approved_logs = Decidim::Bih::VolunteerLog.approved.where(organization:)
        opportunities = Decidim::Bih::VolunteerOpportunity.publicly_visible.where(organization:)

        Volunteering.new(
          approved_hours: approved_logs.sum(:hours).to_i,
          approved_logs: approved_logs.count,
          active_opportunities: opportunities.count,
          upcoming_opportunities: opportunities.where(starts_at: now..).count,
          volunteers: approved_logs.distinct.count(:decidim_user_id)
        )
      end

      def komsiluk_summary
        scope = Decidim::Bih::KomsilukPost.where(organization:)

        Komsiluk.new(
          posts: scope.count,
          visible: scope.visible.count,
          closed: scope.where(status: "closed").count,
          hidden: scope.where(status: "hidden").count,
          expired: scope.where(status: "expired").count,
          recent: scope.where(created_at: current_period).count,
          active_komsiluci: scope.distinct.count(:komsiluk_id),
          category_counts: scope.group(:category).count
        )
      end

      def trend_metrics
        [
          trend_metric(
            :reports_created,
            report_scope.where(created_at: current_period).count,
            report_scope.where(created_at: previous_period).count
          ),
          trend_metric(
            :reports_resolved,
            reports_resolved_in(current_period),
            reports_resolved_in(previous_period)
          ),
          trend_metric(
            :goodwill_points_earned,
            goodwill_points_in(current_period),
            goodwill_points_in(previous_period)
          ),
          trend_metric(
            :volunteer_hours_verified,
            volunteer_hours_in(current_period),
            volunteer_hours_in(previous_period)
          ),
          trend_metric(
            :komsiluk_posts_created,
            komsiluk_posts_in(current_period),
            komsiluk_posts_in(previous_period)
          )
        ]
      end

      def trend_metric(key, current, previous)
        current = current.to_i
        previous = previous.to_i

        TrendMetric.new(key:, current:, previous:, delta: current - previous)
      end

      def reports_resolved_in(period)
        report_scope.resolved.select { |report| resolved_in_period?(report, period) }.count
      end

      def resolved_in_period?(report, period)
        resolved_at = report.resolved_at
        resolved_at.present? && period.cover?(resolved_at)
      end

      def goodwill_points_in(period)
        goodwill_earn_entries
          .where(decidim_bih_goodwill_transactions: { created_at: period })
          .sum("decidim_bih_goodwill_entries.amount")
          .to_i
      end

      def volunteer_hours_in(period)
        approved_logs = Decidim::Bih::VolunteerLog.approved.where(organization:)
        approved_logs
          .where(verified_at: period)
          .or(approved_logs.where(verified_at: nil, created_at: period))
          .sum(:hours)
          .to_i
      end

      def komsiluk_posts_in(period)
        Decidim::Bih::KomsilukPost
          .where(organization:, created_at: period)
          .where.not(status: "hidden")
          .count
      end

      def area_activity
        reports = report_counts_by_mz
        resolved = resolved_report_counts_by_mz
        posts = komsiluk_post_counts_by_mz
        slugs = (reports.keys + resolved.keys + posts.keys).compact.uniq
        names = local_area_names(slugs)

        rows = slugs.map do |slug|
          total = reports[slug].to_i + posts[slug].to_i
          AreaActivity.new(
            slug:,
            name: names[slug] || slug,
            reports: reports[slug].to_i,
            resolved_reports: resolved[slug].to_i,
            komsiluk_posts: posts[slug].to_i,
            total:
          )
        end

        rows
          .select { |area| area.total >= MIN_PUBLIC_CELL }
          .sort_by { |area| [-area.total, area.name.to_s] }
          .first(area_limit)
      end

      def now
        @now ||= Time.current
      end

      def lookback_days
        (lookback_duration / 1.day).round
      end

      def lookback_duration
        now - since
      end

      def current_period
        since...now
      end

      def previous_period
        (since - lookback_duration)...since
      end

      def report_counts_by_mz
        report_scope.where.not(mz_slug: [nil, ""]).group(:mz_slug).count
      end

      def resolved_report_counts_by_mz
        report_scope.resolved.where.not(mz_slug: [nil, ""]).group(:mz_slug).count
      end

      def komsiluk_post_counts_by_mz
        Decidim::Bih::KomsilukPost
          .where(organization:)
          .joins(
            "INNER JOIN decidim_bih_local_areas impact_areas " \
            "ON impact_areas.id = decidim_bih_komsiluk_posts.komsiluk_id"
          )
          .group("COALESCE(NULLIF(impact_areas.primary_mz_slug, ''), impact_areas.slug)")
          .count
      end

      def local_area_names(slugs)
        return {} if slugs.empty?

        Decidim::Bih::LocalArea
          .where(decidim_organization_id: organization.id, slug: slugs)
          .each_with_object({}) { |area, acc| acc[area.slug] ||= area.translated_name }
      end

      def value_of(object, key)
        if object.respond_to?(key)
          object.public_send(key)
        elsif object.respond_to?(:[])
          object[key] || object[key.to_s]
        end
      end

      def decimal_value(value)
        Decidim::Bih::DonationReconciliation.decimal_value(value)
      end
    end
  end
end

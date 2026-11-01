# frozen_string_literal: true

require "csv"
require "bigdecimal"

module Decidim
  module Bih
    module Admin
      # PII-safe read model for host internal analytics.
      #
      # Contract: CSV rows are counts/totals only. The admin page may additionally
      # show bounded, anonymous MI bot prompt/reply examples after a helpful/not
      # helpful click, but never IDs, session digests, account links, contact
      # fields, member lists, recipients, user names, nicknames, emails, or phone
      # numbers.
      class AnalyticsSummary
        DATASETS = %w(
          donations reports report_triage goodwill reward_fulfillment_review onboarding volunteering
          komsiluk komsiluk_activity_review mi_bot_usage mi_bot_feedback mi_bot_review
          mi_bot_review_comparison mi_bot_metrics trends race_standings
        ).freeze
        TREND_WINDOW_DAYS = 30
        KOMSILUK_EXPIRING_REVIEW_DAYS = 7
        REWARD_FULFILLMENT_EXPIRING_REVIEW_DAYS = 7
        MI_BOT_REVIEW_EXAMPLE_TEXT_LIMIT = 900

        HEADERS = {
          "mi_bot_metrics" => ConciergeMetricsSummary::HEADERS,
          "donations" => %w(scope decidim_project_id project_title campaign total_amount donation_orders_count currency as_of),
          "reports" => %w(mz_slug category severity status count first_reported_on last_reported_on),
          "report_triage" => %w(
            bucket count review_priority review_action oldest_attention_on
            oldest_reported_on latest_reported_on forwarding_sla_days stale_days
          ),
          "goodwill" => %w(kind transactions_count positive_points negative_points first_transaction_on last_transaction_on),
          "reward_fulfillment_review" => %w(
            reward_key reward_name review_priority review_action fulfillments_count open_count
            requested_count reserved_count fulfilled_count canceled_count reversed_count
            expired_open_count expiring_open_count events_count latest_event_type
            oldest_opened_on latest_status_on latest_event_on next_expiry_on stock_remaining stock_total
          ),
          "onboarding" => %w(metric status count first_seen_on last_seen_on),
          "volunteering" => %w(metric status count hours),
          "komsiluk" => %w(metric area_slug area_name category_or_channels status count total_flags total_recipients first_seen_on last_seen_on),
          "komsiluk_activity_review" => %w(
            area_slug area_name review_priority review_action posts_count urgent_posts_count hidden_posts_count
            flagged_posts_count expired_posts_count expiring_posts_count total_flags broadcasts_count
            viber_broadcasts_count total_recipients first_post_on last_post_on
            first_broadcast_on last_broadcast_on
          ),
          "mi_bot_feedback" => %w(
            rating outcome answer_intent locale count average_reply_length
            average_quick_replies_count first_feedback_on last_feedback_on
          ),
          "mi_bot_usage" => %w(
            channel outcome answer_intent locale count average_message_length
            average_reply_length average_quick_replies_count sticker_count
            first_seen_on last_seen_on
          ),
          "mi_bot_review" => %w(
            outcome answer_intent locale feedback_count helpful_count not_helpful_count not_helpful_rate
            average_reply_length average_quick_replies_count review_priority review_action
            first_feedback_on last_feedback_on
          ),
          "mi_bot_review_comparison" => %w(
            outcome answer_intent locale current_not_helpful_count previous_not_helpful_count
            change_value change_percent decreased current_total_feedback previous_total_feedback
            window_days current_started_on current_ended_on previous_started_on previous_ended_on
          ),
          "trends" => %w(
            metric unit current_value previous_value change_value change_percent
            window_days current_started_on current_ended_on previous_started_on previous_ended_on
          ),
          "race_standings" => %w(
            rank_overall rank_in_zone komsiluk_slug komsiluk_name zona score registered
            reports proposals reached_at computed_at final
          )
        }.freeze

        ROW_BUILDERS = {
          "mi_bot_metrics" => :mi_bot_metrics_rows,
          "donations" => :donation_rows,
          "reports" => :report_rows,
          "report_triage" => :report_triage_rows,
          "goodwill" => :goodwill_rows,
          "reward_fulfillment_review" => :reward_fulfillment_review_rows,
          "onboarding" => :onboarding_rows,
          "volunteering" => :volunteering_rows,
          "komsiluk" => :komsiluk_rows,
          "komsiluk_activity_review" => :komsiluk_activity_review_rows,
          "mi_bot_usage" => :mi_bot_usage_rows,
          "mi_bot_feedback" => :mi_bot_feedback_rows,
          "mi_bot_review" => :mi_bot_review_rows,
          "mi_bot_review_comparison" => :mi_bot_review_comparison_rows,
          "trends" => :trend_rows,
          "race_standings" => :race_standings_rows
        }.freeze

        def initialize(organization:, now: Time.current, trend_window_days: TREND_WINDOW_DAYS, metric_filters: {})
          @organization = organization
          @trend_now = now
          @trend_window_days = trend_window_days
          @rows = {}
          @metric_filters = metric_filters
        end

        def rows_for(dataset)
          dataset = dataset.to_s
          builder = ROW_BUILDERS[dataset]
          raise ArgumentError, "unknown analytics dataset: #{dataset}" unless builder

          @rows[dataset] ||= send(builder)
        end

        def csv_for(dataset)
          headers = HEADERS.fetch(dataset.to_s)
          CSV.generate(headers: true) do |csv|
            csv << headers
            rows_for(dataset).each do |row|
              csv << headers.map { |header| safe_csv_value(row[header.to_sym]) }
            end
          end
        end

        def concierge_metrics
          @concierge_metrics ||= ConciergeMetricsSummary.new(organization:, now: trend_now, **@metric_filters)
        end

        def mi_bot_metrics_rows
          concierge_metrics.rows
        end

        def registration_funnel
          @registration_funnel ||= RegistrationFunnel.new(organization:, now: @trend_now).call
        end

        def overview
          DATASETS.index_with { |dataset| rows_for(dataset).size }
        end

        def mi_bot_answer_review_queue(limit: 8)
          rows_for("mi_bot_review")
            .reject { |row| row[:review_priority] == "monitor" }
            .first(limit)
        end

        def mi_bot_answer_review_examples(limit: 8)
          feedback_relation = Decidim::Bih::ConciergeFeedback
                              .where(organization:)
                              .where.not(citizen_message: [nil, ""])
                              .where.not(bot_reply_text: [nil, ""])

          records = feedback_relation.where(value: "not_helpful").recent.limit(limit).to_a
          remaining = limit - records.size
          records += feedback_relation.where(value: "helpful").recent.limit(remaining).to_a if remaining.positive?

          records.map { |feedback| mi_bot_feedback_example_row(feedback) }
        end

        # Bounded-window answer-quality alert for the operations health channel.
        #
        # Deliberately NOT one of the DATASETS: the cumulative mi_bot_review
        # queue stays exactly as it is (it is the operator's working list), and
        # this is the separate, recent-window question "did a bucket go bad in
        # the last seven days?". Keeping them apart is the point — see
        # ChatFeedbackAlert.
        def chat_feedback_alert(**options)
          @chat_feedback_alert ||= {}
          @chat_feedback_alert[options] ||=
            Decidim::Bih::Admin::ChatFeedbackAlert.new(organization:, now: trend_now, **options)
        end

        # Operator chat-health read model for the selected period; nil figures
        # mean "not instrumented", never zero.
        def chat_health(period_days: Decidim::Bih::Admin::ChatHealthSummary::DEFAULT_PERIOD)
          @chat_health ||= {}
          @chat_health[period_days] ||= Decidim::Bih::Admin::ChatHealthSummary.new(organization:, period_days:, now: trend_now)
        end

        def digest_sections(limit: 6)
          {
            overview:,
            report_triage: active_report_triage_rows(limit:),
            reward_fulfillment_review: active_review_rows("reward_fulfillment_review", limit:),
            komsiluk_activity_review: active_review_rows("komsiluk_activity_review", limit:),
            mi_bot_review: active_review_rows("mi_bot_review", limit:),
            mi_bot_review_comparison: rows_for("mi_bot_review_comparison").first(limit),
            trends: rows_for("trends")
          }
        end

        private

        attr_reader :organization, :trend_now, :trend_window_days

        def donation_rows
          provider = Decidim::Bih.donations_provider_for(organization:)
          return [] unless provider

          [
            donation_row(scope: "general", totals: provider.totals, provider:),
            *project_donation_rows(provider)
          ].compact
        end

        def active_report_triage_rows(limit:)
          rows_for("report_triage")
            .select { |row| row[:count].to_i.positive? }
            .first(limit)
        end

        def active_review_rows(dataset, limit:)
          rows_for(dataset)
            .reject { |row| row[:review_priority] == "monitor" }
            .first(limit)
        end

        def project_donation_rows(provider)
          return [] unless provider.respond_to?(:project_mappings)

          Array(provider_project_mappings(provider)).map do |project|
            donation_row(scope: "project", project:, totals: value_of(project, :totals), provider:)
          end
        end

        def provider_project_mappings(provider)
          provider.project_mappings(organization:)
        rescue ArgumentError
          provider.project_mappings
        end

        def donation_row(scope:, totals:, provider:, project: nil)
          return unless totals

          {
            scope:,
            decidim_project_id: value_of(project, :decidim_project_id),
            project_title: value_of(project, :title),
            campaign: value_of(project, :campaign),
            total_amount: decimal_value(value_of(totals, :total)),
            donation_orders_count: value_of(totals, :count).to_i,
            currency: value_of(totals, :currency).presence || value_of(provider, :currency_label),
            as_of: datetime_value(value_of(totals, :as_of))
          }
        end

        def report_rows
          Decidim::Bih::Report
            .where(organization:)
            .group(:mz_slug, :category, :severity, Arel.sql(ReportStatusPresenter::DISPLAY_STATUS_SQL))
            .pluck(
              :mz_slug,
              :category,
              :severity,
              Arel.sql(ReportStatusPresenter::DISPLAY_STATUS_SQL),
              Arel.sql("COUNT(*)"),
              Arel.sql("MIN(created_at)"),
              Arel.sql("MAX(created_at)")
            )
            .map do |row|
              mz_slug, category, severity, status, count, first_at, last_at = row
              {
                mz_slug: mz_slug.presence || "unknown",
                category: category.presence || "unknown",
                severity: severity.presence || "unknown",
                status:,
                count: count.to_i,
                first_reported_on: date_value(first_at),
                last_reported_on: date_value(last_at)
              }
            end
        end

        def report_triage_rows
          Decidim::Bih::Admin::ReportTriageSummary.new(
            organization:,
            now: trend_now
          ).rows
        end

        def goodwill_rows
          Decidim::Bih::Goodwill::Entry
            .joins(:ledger_transaction)
            .where(organization:)
            .group("decidim_bih_goodwill_transactions.kind")
            .pluck(
              "decidim_bih_goodwill_transactions.kind",
              Arel.sql("COUNT(DISTINCT decidim_bih_goodwill_transactions.id)"),
              Arel.sql("SUM(CASE WHEN decidim_bih_goodwill_entries.amount > 0 THEN decidim_bih_goodwill_entries.amount ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN decidim_bih_goodwill_entries.amount < 0 THEN -decidim_bih_goodwill_entries.amount ELSE 0 END)"),
              Arel.sql("MIN(decidim_bih_goodwill_transactions.created_at)"),
              Arel.sql("MAX(decidim_bih_goodwill_transactions.created_at)")
            )
            .map do |row|
              kind, count, positive_points, negative_points, first_at, last_at = row
              {
                kind:,
                transactions_count: count.to_i,
                positive_points: positive_points.to_i,
                negative_points: negative_points.to_i,
                first_transaction_on: date_value(first_at),
                last_transaction_on: date_value(last_at)
              }
            end
        end

        def reward_fulfillment_review_rows
          reward_lookup = Decidim::Bih::Goodwill::RewardsCatalog
                          .all(organization)
                          .index_by(&:key)
          event_metrics = reward_fulfillment_event_metrics

          rows = reward_fulfillment_status_metrics.map do |reward_key, metrics|
            reward = reward_lookup[reward_key]
            reward_fulfillment_review_row(
              reward_key:,
              reward:,
              metrics:,
              event_metrics: event_metrics.fetch(reward_key, {})
            )
          end

          rows.sort_by { |row| reward_fulfillment_review_sort_key(row) }
        end

        def reward_fulfillment_status_metrics
          expiring_before = trend_now + REWARD_FULFILLMENT_EXPIRING_REVIEW_DAYS.days
          Decidim::Bih::Goodwill::RewardFulfillment
            .where(organization:)
            .group(:reward_key)
            .pluck(
              :reward_key,
              Arel.sql("COUNT(*)"),
              Arel.sql("SUM(CASE WHEN status = 'requested' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN status = 'reserved' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN status = 'fulfilled' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN status = 'canceled' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN status = 'reversed' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN status IN ('requested', 'reserved') THEN 1 ELSE 0 END)"),
              Arel.sql(
                ActiveRecord::Base.sanitize_sql_array(
                  [
                    "SUM(CASE WHEN status IN ('requested', 'reserved') " \
                    "AND reward_expires_at IS NOT NULL AND reward_expires_at < ? THEN 1 ELSE 0 END)",
                    trend_now
                  ]
                )
              ),
              Arel.sql(
                ActiveRecord::Base.sanitize_sql_array(
                  [
                    "SUM(CASE WHEN status IN ('requested', 'reserved') " \
                    "AND reward_expires_at IS NOT NULL AND reward_expires_at >= ? " \
                    "AND reward_expires_at <= ? THEN 1 ELSE 0 END)",
                    trend_now,
                    expiring_before
                  ]
                )
              ),
              Arel.sql("MIN(CASE WHEN status IN ('requested', 'reserved') THEN created_at END)"),
              Arel.sql("MAX(COALESCE(handled_at, updated_at, created_at))"),
              Arel.sql("MIN(CASE WHEN status IN ('requested', 'reserved') THEN reward_expires_at END)")
            )
            .each_with_object({}) do |row, metrics|
              reward_key, fulfillments_count, requested_count, reserved_count,
                fulfilled_count, canceled_count, reversed_count, open_count,
                expired_open_count, expiring_open_count, oldest_opened_at,
                latest_status_at, next_expiry_at = row
              metrics[reward_key] = {
                fulfillments_count: fulfillments_count.to_i,
                requested_count: requested_count.to_i,
                reserved_count: reserved_count.to_i,
                fulfilled_count: fulfilled_count.to_i,
                canceled_count: canceled_count.to_i,
                reversed_count: reversed_count.to_i,
                open_count: open_count.to_i,
                expired_open_count: expired_open_count.to_i,
                expiring_open_count: expiring_open_count.to_i,
                oldest_opened_on: date_value(oldest_opened_at),
                latest_status_on: date_value(latest_status_at),
                next_expiry_on: date_value(next_expiry_at)
              }
            end
        end

        def reward_fulfillment_event_metrics
          return {} unless Decidim::Bih::Goodwill::RewardFulfillmentEvent.available?

          Decidim::Bih::Goodwill::RewardFulfillmentEvent
            .joins(:fulfillment)
            .where(organization:)
            .order(
              Arel.sql(
                "decidim_bih_goodwill_reward_fulfillments.reward_key ASC, " \
                "decidim_bih_goodwill_reward_fulfillment_events.occurred_at DESC, " \
                "decidim_bih_goodwill_reward_fulfillment_events.id DESC"
              )
            )
            .pluck(
              Arel.sql("decidim_bih_goodwill_reward_fulfillments.reward_key"),
              :event_type,
              :occurred_at
            )
            .each_with_object({}) do |(reward_key, event_type, occurred_at), metrics|
              row = (metrics[reward_key] ||= { events_count: 0 })
              row[:events_count] += 1
              next if row[:latest_event_type].present?

              row[:latest_event_type] = event_type
              row[:latest_event_on] = date_value(occurred_at)
            end
        end

        def reward_fulfillment_review_row(reward_key:, reward:, metrics:, event_metrics:)
          row = {
            reward_key:,
            reward_name: reward&.name || reward_key,
            fulfillments_count: metrics.fetch(:fulfillments_count, 0),
            open_count: metrics.fetch(:open_count, 0),
            requested_count: metrics.fetch(:requested_count, 0),
            reserved_count: metrics.fetch(:reserved_count, 0),
            fulfilled_count: metrics.fetch(:fulfilled_count, 0),
            canceled_count: metrics.fetch(:canceled_count, 0),
            reversed_count: metrics.fetch(:reversed_count, 0),
            expired_open_count: metrics.fetch(:expired_open_count, 0),
            expiring_open_count: metrics.fetch(:expiring_open_count, 0),
            events_count: event_metrics.fetch(:events_count, 0),
            latest_event_type: event_metrics[:latest_event_type],
            oldest_opened_on: metrics[:oldest_opened_on],
            latest_status_on: metrics[:latest_status_on],
            latest_event_on: event_metrics[:latest_event_on],
            next_expiry_on: metrics[:next_expiry_on] || date_value(reward&.expires_at),
            stock_remaining: reward&.remaining_stock(organization),
            stock_total: reward&.stock
          }

          row.merge(
            review_priority: reward_fulfillment_review_priority(row),
            review_action: reward_fulfillment_review_action(row)
          )
        end

        def reward_fulfillment_review_priority(row)
          return "high" if row[:expired_open_count].positive? ||
                           (row[:open_count].positive? && row[:stock_remaining].to_i.zero? &&
                            !row[:stock_remaining].nil?)
          return "watch" if row[:open_count].positive? ||
                            row[:expiring_open_count].positive? ||
                            row[:canceled_count].positive? ||
                            row[:reversed_count].positive?

          "monitor"
        end

        def reward_fulfillment_review_action(row)
          return "check_expired_open_requests" if row[:expired_open_count].positive?
          return "review_stock_before_reserving" if row[:open_count].positive? &&
                                                    row[:stock_remaining].to_i.zero? &&
                                                    !row[:stock_remaining].nil?
          return "prepare_pickup_or_delivery" if row[:reserved_count].positive?
          return "review_new_requests" if row[:requested_count].positive?
          return "review_recent_cancellations" if row[:canceled_count].positive? || row[:reversed_count].positive?

          "continue_monitoring"
        end

        def reward_fulfillment_review_sort_key(row)
          [
            { "high" => 0, "watch" => 1, "monitor" => 2 }.fetch(row[:review_priority], 3),
            -row[:expired_open_count].to_i,
            -row[:open_count].to_i,
            -row[:events_count].to_i,
            row[:reward_key].to_s
          ]
        end

        def volunteering_rows
          opportunity_rows + volunteer_log_rows + signup_rows
        end

        def onboarding_rows
          users = Decidim::User.where(decidim_organization_id: organization.id)
          authorizations = Decidim::Authorization.where(user: users)

          [
            aggregate_row("registrations", "created", users),
            aggregate_row("registrations", "email_confirmed", users.where.not(confirmed_at: nil), time_column: :confirmed_at),
            aggregate_row("registrations", "notifications_customized", users.where.not(notification_types: "all")),
            aggregate_row("verification", "sms_requested", authorizations.where(name: "sms")),
            aggregate_row("verification", "sms_granted", authorizations.where(name: "sms").where.not(granted_at: nil), time_column: :granted_at),
            aggregate_row("verification", "postal_requested", authorizations.where(name: "postal_letter")),
            aggregate_row(
              "verification",
              "postal_granted",
              authorizations.where(name: "postal_letter").where.not(granted_at: nil),
              time_column: :granted_at
            ),
            aggregate_row("localization", "komsiluk_assigned", Decidim::Bih::CitizenProfile.where(organization:).where.not(komsiluk_id: nil), time_column: :assigned_at),
            aggregate_row("messaging", "viber_linked", Decidim::Bih::Viber::Linkage.where(organization:).where.not(decidim_user_id: nil)),
            distinct_user_row(
              "first_action",
              "submitted_report",
              Decidim::Bih::Report.where(organization:),
              user_column: :decidim_user_id
            ),
            distinct_user_row(
              "first_action",
              "volunteer_signup",
              Decidim::Bih::VolunteerSignup.where(organization:),
              user_column: :decidim_user_id
            ),
            distinct_user_row(
              "first_action",
              "volunteer_availability",
              Decidim::Bih::VolunteerAvailability.where(organization:),
              user_column: :decidim_user_id
            ),
            distinct_user_row(
              "first_action",
              "reward_requested",
              Decidim::Bih::Goodwill::RewardFulfillment.where(organization:),
              user_column: :decidim_user_id
            )
          ]
        end

        def opportunity_rows
          Decidim::Bih::VolunteerOpportunity
            .where(organization:)
            .group(:review_status, :active)
            .count
            .map do |(status, active), count|
              {
                metric: "opportunities",
                status: "#{status}:#{active ? "active" : "inactive"}",
                count:,
                hours: nil
              }
            end
        end

        def volunteer_log_rows
          Decidim::Bih::VolunteerLog
            .where(organization:)
            .group(:status)
            .pluck(:status, Arel.sql("COUNT(*)"), Arel.sql("SUM(hours)"))
            .map do |status, count, hours|
              {
                metric: "volunteer_logs",
                status:,
                count: count.to_i,
                hours: hours.to_i
              }
            end
        end

        def signup_rows
          Decidim::Bih::VolunteerSignup
            .where(organization:)
            .group(:status)
            .count
            .map do |status, count|
              {
                metric: "signups",
                status:,
                count:,
                hours: nil
              }
            end
        end

        def komsiluk_rows
          area_lookup = Decidim::Bih::LocalArea
                        .where(organization:)
                        .index_by(&:id)
          komsiluk_post_rows(area_lookup) + broadcast_rows(area_lookup)
        end

        def komsiluk_post_rows(area_lookup)
          Decidim::Bih::KomsilukPost
            .where(organization:)
            .group(:komsiluk_id, :category, :status)
            .pluck(
              :komsiluk_id,
              :category,
              :status,
              Arel.sql("COUNT(*)"),
              Arel.sql("SUM(flagged_count)"),
              Arel.sql("MIN(created_at)"),
              Arel.sql("MAX(created_at)")
            )
            .map do |row|
              area_id, category, status, count, flags, first_at, last_at = row
              area = area_lookup[area_id]
              {
                metric: "posts",
                area_slug: area&.slug || area_id,
                area_name: area&.translated_name || area_id,
                category_or_channels: category,
                status:,
                count: count.to_i,
                total_flags: flags.to_i,
                total_recipients: nil,
                first_seen_on: date_value(first_at),
                last_seen_on: date_value(last_at)
              }
            end
        end

        def broadcast_rows(area_lookup)
          Decidim::Bih::Broadcast
            .where(organization:)
            .group(:local_area_id, :channels)
            .pluck(
              :local_area_id,
              :channels,
              Arel.sql("COUNT(*)"),
              Arel.sql("SUM(recipients_count)"),
              Arel.sql("MIN(created_at)"),
              Arel.sql("MAX(created_at)")
            )
            .map do |row|
              area_id, channels, count, recipients, first_at, last_at = row
              area = area_lookup[area_id]
              {
                metric: "broadcasts",
                area_slug: area&.slug || area_id,
                area_name: area&.translated_name || area_id,
                category_or_channels: channels,
                status: nil,
                count: count.to_i,
                total_flags: nil,
                total_recipients: recipients.to_i,
                first_seen_on: date_value(first_at),
                last_seen_on: date_value(last_at)
              }
            end
        end

        def komsiluk_activity_review_rows
          area_lookup = Decidim::Bih::LocalArea
                        .where(organization:)
                        .index_by(&:id)
          post_metrics = komsiluk_activity_review_post_metrics
          broadcast_metrics = komsiluk_activity_review_broadcast_metrics

          rows = (post_metrics.keys | broadcast_metrics.keys).filter_map do |area_id|
            area = area_lookup[area_id]
            next unless area

            komsiluk_activity_review_row(
              area:,
              post_metrics: post_metrics.fetch(area_id, {}),
              broadcast_metrics: broadcast_metrics.fetch(area_id, {})
            )
          end

          rows.sort_by { |row| komsiluk_activity_review_sort_key(row) }
        end

        def komsiluk_activity_review_post_metrics
          expiring_before = trend_now + KOMSILUK_EXPIRING_REVIEW_DAYS.days
          Decidim::Bih::KomsilukPost
            .where(organization:)
            .group(:komsiluk_id)
            .pluck(
              :komsiluk_id,
              Arel.sql("COUNT(*)"),
              Arel.sql("SUM(CASE WHEN category IN ('lost_pet', 'safety') THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN status = 'hidden' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN flagged_count > 0 THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN status = 'expired' THEN 1 ELSE 0 END)"),
              Arel.sql(
                ActiveRecord::Base.sanitize_sql_array(
                  [
                    "SUM(CASE WHEN status = 'open' AND expires_at IS NOT NULL " \
                    "AND expires_at <= ? THEN 1 ELSE 0 END)",
                    expiring_before
                  ]
                )
              ),
              Arel.sql("SUM(flagged_count)"),
              Arel.sql("MIN(created_at)"),
              Arel.sql("MAX(created_at)")
            )
            .each_with_object({}) do |row, metrics|
              area_id, posts_count, urgent_posts_count, hidden_posts_count,
                flagged_posts_count, expired_posts_count, expiring_posts_count,
                total_flags, first_post_at, last_post_at = row
              metrics[area_id] = {
                posts_count: posts_count.to_i,
                urgent_posts_count: urgent_posts_count.to_i,
                hidden_posts_count: hidden_posts_count.to_i,
                flagged_posts_count: flagged_posts_count.to_i,
                expired_posts_count: expired_posts_count.to_i,
                expiring_posts_count: expiring_posts_count.to_i,
                total_flags: total_flags.to_i,
                first_post_on: date_value(first_post_at),
                last_post_on: date_value(last_post_at)
              }
            end
        end

        def komsiluk_activity_review_broadcast_metrics
          Decidim::Bih::Broadcast
            .where(organization:)
            .group(:local_area_id)
            .pluck(
              :local_area_id,
              Arel.sql("COUNT(*)"),
              Arel.sql("SUM(CASE WHEN channels LIKE '%viber%' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(recipients_count)"),
              Arel.sql("MIN(created_at)"),
              Arel.sql("MAX(created_at)")
            )
            .each_with_object({}) do |row, metrics|
              area_id, broadcasts_count, viber_broadcasts_count, total_recipients,
                first_broadcast_at, last_broadcast_at = row
              metrics[area_id] = {
                broadcasts_count: broadcasts_count.to_i,
                viber_broadcasts_count: viber_broadcasts_count.to_i,
                total_recipients: total_recipients.to_i,
                first_broadcast_on: date_value(first_broadcast_at),
                last_broadcast_on: date_value(last_broadcast_at)
              }
            end
        end

        def komsiluk_activity_review_row(area:, post_metrics:, broadcast_metrics:)
          row = {
            area_slug: area.slug,
            area_name: area.translated_name,
            posts_count: post_metrics.fetch(:posts_count, 0),
            urgent_posts_count: post_metrics.fetch(:urgent_posts_count, 0),
            hidden_posts_count: post_metrics.fetch(:hidden_posts_count, 0),
            flagged_posts_count: post_metrics.fetch(:flagged_posts_count, 0),
            expired_posts_count: post_metrics.fetch(:expired_posts_count, 0),
            expiring_posts_count: post_metrics.fetch(:expiring_posts_count, 0),
            total_flags: post_metrics.fetch(:total_flags, 0),
            broadcasts_count: broadcast_metrics.fetch(:broadcasts_count, 0),
            viber_broadcasts_count: broadcast_metrics.fetch(:viber_broadcasts_count, 0),
            total_recipients: broadcast_metrics.fetch(:total_recipients, 0),
            first_post_on: post_metrics[:first_post_on],
            last_post_on: post_metrics[:last_post_on],
            first_broadcast_on: broadcast_metrics[:first_broadcast_on],
            last_broadcast_on: broadcast_metrics[:last_broadcast_on]
          }

          row.merge(
            review_priority: komsiluk_activity_review_priority(row),
            review_action: komsiluk_activity_review_action(row)
          )
        end

        def komsiluk_activity_review_priority(row)
          return "high" if row[:hidden_posts_count].positive? ||
                           row[:total_flags].to_i >= Decidim::Bih::KomsilukPost::FLAG_HIDE_THRESHOLD
          return "watch" if row[:urgent_posts_count].positive? ||
                            row[:flagged_posts_count].positive? ||
                            row[:expired_posts_count].positive? ||
                            row[:expiring_posts_count].positive? ||
                            row[:viber_broadcasts_count].positive? ||
                            row[:total_recipients].positive?

          "monitor"
        end

        def komsiluk_activity_review_action(row)
          return "review_moderation_queue" if row[:hidden_posts_count].positive? || row[:flagged_posts_count].positive?
          return "check_expired_cleanup" if row[:expired_posts_count].positive?
          return "check_expiring_posts" if row[:expiring_posts_count].positive?
          return "check_urgent_followup" if row[:urgent_posts_count].positive?
          return "review_broadcast_reach" if row[:viber_broadcasts_count].positive? || row[:total_recipients].positive?

          "continue_monitoring"
        end

        def komsiluk_activity_review_sort_key(row)
          [
            { "high" => 0, "watch" => 1, "monitor" => 2 }.fetch(row[:review_priority], 3),
            -row[:hidden_posts_count].to_i,
            -row[:total_flags].to_i,
            -row[:urgent_posts_count].to_i,
            -row[:total_recipients].to_i,
            row[:area_slug].to_s
          ]
        end

        def mi_bot_feedback_rows
          Decidim::Bih::ConciergeFeedback
            .where(organization:)
            .group(
              :value,
              :locale,
              Arel.sql("COALESCE(metadata->>'outcome', 'unknown')"),
              Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')")
            )
            .pluck(
              :value,
              :locale,
              Arel.sql("COALESCE(metadata->>'outcome', 'unknown')"),
              Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')"),
              Arel.sql("COUNT(*)"),
              Arel.sql("AVG(CASE WHEN metadata->>'reply_length' ~ '^[0-9]+$' THEN (metadata->>'reply_length')::integer END)"),
              Arel.sql("AVG(CASE WHEN metadata->>'quick_replies_count' ~ '^[0-9]+$' THEN (metadata->>'quick_replies_count')::integer END)"),
              Arel.sql("MIN(created_at)"),
              Arel.sql("MAX(updated_at)")
            )
            .map do |row|
              value, locale, outcome, answer_intent, count, average_reply_length,
                average_quick_replies_count, first_at, last_at = row
              {
                rating: value,
                outcome: outcome.presence || "unknown",
                answer_intent: answer_intent.presence || "unknown",
                locale: locale.presence || "unknown",
                count: count.to_i,
                average_reply_length: rounded_average(average_reply_length),
                average_quick_replies_count: rounded_average(average_quick_replies_count),
                first_feedback_on: date_value(first_at),
                last_feedback_on: date_value(last_at)
              }
            end
        end

        def mi_bot_usage_rows
          Decidim::Bih::ConciergeUsageAggregate
            .where(organization:)
            .group(:channel, :outcome, :answer_intent, :locale)
            .pluck(
              :channel,
              :outcome,
              :answer_intent,
              :locale,
              Arel.sql("SUM(requests_count)"),
              Arel.sql("SUM(message_length_total)"),
              Arel.sql("SUM(reply_length_total)"),
              Arel.sql("SUM(quick_replies_total)"),
              Arel.sql("SUM(sticker_count)"),
              Arel.sql("MIN(bucket_on)"),
              Arel.sql("MAX(bucket_on)")
            )
            .map do |row|
              channel, outcome, answer_intent, locale, count, message_total, reply_total,
                quick_total, sticker_count, first_on, last_on = row
              count = count.to_i

              {
                channel: channel.presence || "unknown",
                outcome: outcome.presence || "unknown",
                answer_intent: answer_intent.presence || "unknown",
                locale: locale.presence || "unknown",
                count:,
                average_message_length: count >= 2 ? rounded_ratio(message_total, count) : nil,
                average_reply_length: rounded_ratio(reply_total, count),
                average_quick_replies_count: rounded_ratio(quick_total, count),
                sticker_count: sticker_count.to_i,
                first_seen_on: date_value(first_on),
                last_seen_on: date_value(last_on)
              }
            end
        end

        def mi_bot_review_rows
          Decidim::Bih::ConciergeFeedback
            .where(organization:)
            .group(
              :locale,
              Arel.sql("COALESCE(metadata->>'outcome', 'unknown')"),
              Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')")
            )
            .pluck(
              :locale,
              Arel.sql("COALESCE(metadata->>'outcome', 'unknown')"),
              Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')"),
              Arel.sql("COUNT(*)"),
              Arel.sql("SUM(CASE WHEN value = 'helpful' THEN 1 ELSE 0 END)"),
              Arel.sql("SUM(CASE WHEN value = 'not_helpful' THEN 1 ELSE 0 END)"),
              Arel.sql("AVG(CASE WHEN metadata->>'reply_length' ~ '^[0-9]+$' THEN (metadata->>'reply_length')::integer END)"),
              Arel.sql("AVG(CASE WHEN metadata->>'quick_replies_count' ~ '^[0-9]+$' THEN (metadata->>'quick_replies_count')::integer END)"),
              Arel.sql("MIN(created_at)"),
              Arel.sql("MAX(updated_at)")
            )
            .map { |row| mi_bot_review_row(row) }
            .sort_by { |row| mi_bot_review_sort_key(row) }
        end

        def mi_bot_review_comparison_rows
          current = mi_bot_feedback_bucket_counts(current_trend_range)
          previous = mi_bot_feedback_bucket_counts(previous_trend_range)
          keys = (current.keys + previous.keys).uniq

          rows = keys.map do |key|
            outcome, answer_intent, locale = key
            current_counts = current.fetch(key, { not_helpful: 0, total: 0 })
            previous_counts = previous.fetch(key, { not_helpful: 0, total: 0 })
            current_not_helpful = current_counts.fetch(:not_helpful)
            previous_not_helpful = previous_counts.fetch(:not_helpful)
            change_value = current_not_helpful - previous_not_helpful

            {
              outcome:,
              answer_intent:,
              locale:,
              current_not_helpful_count: current_not_helpful,
              previous_not_helpful_count: previous_not_helpful,
              change_value:,
              change_percent: trend_percent(decimal_trend_value(current_not_helpful), decimal_trend_value(previous_not_helpful)),
              decreased: previous_not_helpful.positive? && current_not_helpful < previous_not_helpful,
              current_total_feedback: current_counts.fetch(:total),
              previous_total_feedback: previous_counts.fetch(:total),
              window_days: trend_window_days,
              current_started_on: date_value(current_trend_start),
              current_ended_on: date_value(trend_now),
              previous_started_on: date_value(previous_trend_start),
              previous_ended_on: date_value(current_trend_start)
            }
          end
          rows.sort_by { |row| mi_bot_review_comparison_sort_key(row) }
        end

        def mi_bot_feedback_bucket_counts(range)
          Decidim::Bih::ConciergeFeedback
            .where(organization:, created_at: range)
            .group(
              :locale,
              Arel.sql("COALESCE(metadata->>'outcome', 'unknown')"),
              Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')")
            )
            .pluck(
              Arel.sql("COALESCE(metadata->>'outcome', 'unknown')"),
              Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')"),
              :locale,
              Arel.sql("COUNT(*)"),
              Arel.sql("SUM(CASE WHEN value = 'not_helpful' THEN 1 ELSE 0 END)")
            )
            .each_with_object({}) do |row, buckets|
              outcome, answer_intent, locale, total, not_helpful = row
              buckets[[outcome.presence || "unknown", answer_intent.presence || "unknown", locale.presence || "unknown"]] = {
                total: total.to_i,
                not_helpful: not_helpful.to_i
              }
            end
        end

        def mi_bot_review_comparison_sort_key(row)
          [
            row[:decreased] ? 1 : 0,
            -row[:current_not_helpful_count].to_i,
            -row[:previous_not_helpful_count].to_i,
            row[:answer_intent].to_s,
            row[:outcome].to_s,
            row[:locale].to_s
          ]
        end

        def mi_bot_review_row(row)
          locale, outcome, answer_intent, feedback_count, helpful_count, not_helpful_count,
            average_reply_length, average_quick_replies_count, first_at, last_at = row
          feedback_count = feedback_count.to_i
          helpful_count = helpful_count.to_i
          not_helpful_count = not_helpful_count.to_i
          outcome = outcome.presence || "unknown"

          {
            outcome:,
            answer_intent: answer_intent.presence || "unknown",
            locale: locale.presence || "unknown",
            feedback_count:,
            helpful_count:,
            not_helpful_count:,
            not_helpful_rate: rounded_percent(not_helpful_count, feedback_count),
            average_reply_length: rounded_average(average_reply_length),
            average_quick_replies_count: rounded_average(average_quick_replies_count),
            review_priority: mi_bot_review_priority(outcome, feedback_count, helpful_count, not_helpful_count),
            review_action: mi_bot_review_action(outcome, helpful_count, not_helpful_count),
            first_feedback_on: date_value(first_at),
            last_feedback_on: date_value(last_at)
          }
        end

        def mi_bot_review_priority(outcome, feedback_count, helpful_count, not_helpful_count)
          return "high" if high_priority_mi_bot_review?(outcome, feedback_count, not_helpful_count)
          return "watch" if watch_priority_mi_bot_review?(outcome, feedback_count, helpful_count, not_helpful_count)

          "monitor"
        end

        def high_priority_mi_bot_review?(outcome, feedback_count, not_helpful_count)
          not_helpful_rate = feedback_count.positive? ? (not_helpful_count.to_f / feedback_count) : 0.0

          not_helpful_count >= 5 ||
            (not_helpful_count >= 2 && not_helpful_rate >= 0.5) ||
            (outcome == "fallback" && not_helpful_count.positive?)
        end

        def watch_priority_mi_bot_review?(outcome, feedback_count, helpful_count, not_helpful_count)
          not_helpful_count.positive? ||
            (outcome != "success" && feedback_count.positive?) ||
            (helpful_count.zero? && feedback_count.positive?)
        end

        def mi_bot_review_action(outcome, helpful_count, not_helpful_count)
          return "check_resolver_and_city_data" if outcome == "fallback"
          return "review_answer_library" if not_helpful_count > helpful_count
          return "sample_common_intents" if not_helpful_count.positive?

          "continue_monitoring"
        end

        def mi_bot_review_sort_key(row)
          [
            { "high" => 0, "watch" => 1, "monitor" => 2 }.fetch(row[:review_priority], 3),
            -row[:not_helpful_count].to_i,
            -row[:feedback_count].to_i,
            row[:outcome].to_s,
            row[:answer_intent].to_s,
            row[:locale].to_s
          ]
        end

        def mi_bot_feedback_example_row(feedback)
          outcome = feedback.metadata["outcome"].presence || "unknown"
          answer_intent = Decidim::Bih::Concierge::AnswerIntents.sanitize(feedback.metadata["answer_intent"])

          {
            rating: feedback.value,
            outcome:,
            answer_intent:,
            locale: feedback.locale.presence || "unknown",
            feedback_on: date_value(feedback.updated_at || feedback.created_at),
            review_priority: feedback.value == "not_helpful" ? "watch" : "monitor",
            review_action: feedback.value == "not_helpful" ? mi_bot_feedback_example_action(outcome) : "continue_monitoring",
            citizen_message: review_example_text(feedback.citizen_message),
            bot_reply_text: review_example_text(feedback.bot_reply_text)
          }
        end

        def mi_bot_feedback_example_action(outcome)
          return "check_resolver_and_city_data" if outcome == "fallback"

          "review_answer_library"
        end

        def trend_rows
          [
            trend_row(
              "reports_created",
              unit: "count",
              current_value: records_in_window(Decidim::Bih::Report, :created_at, current_trend_range),
              previous_value: records_in_window(Decidim::Bih::Report, :created_at, previous_trend_range)
            ),
            trend_row(
              "goodwill_points_earned",
              unit: "points",
              current_value: goodwill_points_in_window("earn", current_trend_range, positive: true),
              previous_value: goodwill_points_in_window("earn", previous_trend_range, positive: true)
            ),
            trend_row(
              "goodwill_redemptions",
              unit: "count",
              current_value: goodwill_transactions_in_window("redeem", current_trend_range),
              previous_value: goodwill_transactions_in_window("redeem", previous_trend_range)
            ),
            trend_row(
              "goodwill_points_redeemed",
              unit: "points",
              current_value: goodwill_points_in_window("redeem", current_trend_range, positive: false),
              previous_value: goodwill_points_in_window("redeem", previous_trend_range, positive: false)
            ),
            trend_row(
              "volunteer_hours_approved",
              unit: "hours",
              current_value: approved_volunteer_hours_in_window(current_trend_range),
              previous_value: approved_volunteer_hours_in_window(previous_trend_range)
            ),
            trend_row(
              "volunteer_signups",
              unit: "count",
              current_value: records_in_window(Decidim::Bih::VolunteerSignup, :created_at, current_trend_range),
              previous_value: records_in_window(Decidim::Bih::VolunteerSignup, :created_at, previous_trend_range)
            ),
            trend_row(
              "komsiluk_posts",
              unit: "count",
              current_value: records_in_window(Decidim::Bih::KomsilukPost, :created_at, current_trend_range),
              previous_value: records_in_window(Decidim::Bih::KomsilukPost, :created_at, previous_trend_range)
            ),
            trend_row(
              "komsiluk_broadcasts",
              unit: "count",
              current_value: records_in_window(Decidim::Bih::Broadcast, :created_at, current_trend_range),
              previous_value: records_in_window(Decidim::Bih::Broadcast, :created_at, previous_trend_range)
            ),
            trend_row(
              "komsiluk_broadcast_recipients",
              unit: "recipients",
              current_value: broadcast_recipients_in_window(current_trend_range),
              previous_value: broadcast_recipients_in_window(previous_trend_range)
            ),
            trend_row(
              "mi_bot_requests",
              unit: "count",
              current_value: usage_requests_in_window(current_trend_range),
              previous_value: usage_requests_in_window(previous_trend_range)
            ),
            trend_row(
              "mi_bot_feedback",
              unit: "count",
              current_value: records_in_window(Decidim::Bih::ConciergeFeedback, :created_at, current_trend_range),
              previous_value: records_in_window(Decidim::Bih::ConciergeFeedback, :created_at, previous_trend_range)
            ),
            trend_row(
              "mi_bot_helpful_feedback",
              unit: "count",
              current_value: feedback_rating_in_window("helpful", current_trend_range),
              previous_value: feedback_rating_in_window("helpful", previous_trend_range)
            ),
            trend_row(
              "mi_bot_not_helpful_feedback",
              unit: "count",
              current_value: feedback_rating_in_window("not_helpful", current_trend_range),
              previous_value: feedback_rating_in_window("not_helpful", previous_trend_range)
            )
          ]
        end

        # Neighbourhood-level race figures for the daily social posts. Komšiluk
        # names are reference data, not personal data; nothing here identifies a
        # citizen.
        def race_standings_rows
          Decidim::Bih::Race::Standings.new(organization).rows.map do |standing|
            {
              rank_overall: standing.rank_overall,
              rank_in_zone: standing.rank_in_zone,
              komsiluk_slug: standing.komsiluk&.slug,
              komsiluk_name: standing.display_name,
              zona: standing.zona,
              score: standing.score,
              registered: standing.registered,
              reports: standing.reports,
              proposals: standing.proposals,
              reached_at: standing.reached_at&.iso8601,
              computed_at: standing.computed_at&.iso8601,
              final: standing.final
            }
          end
        end

        def trend_row(metric, unit:, current_value:, previous_value:)
          current_value = decimal_trend_value(current_value)
          previous_value = decimal_trend_value(previous_value)
          change_value = current_value - previous_value

          {
            metric:,
            unit:,
            current_value: trend_value(current_value),
            previous_value: trend_value(previous_value),
            change_value: trend_value(change_value),
            change_percent: trend_percent(current_value, previous_value),
            window_days: trend_window_days,
            current_started_on: date_value(current_trend_start),
            current_ended_on: date_value(trend_now),
            previous_started_on: date_value(previous_trend_start),
            previous_ended_on: date_value(current_trend_start)
          }
        end

        def records_in_window(model, column, range)
          model.where(organization:).where(column => range).count
        end

        def aggregate_row(metric, status, relation, time_column: :created_at)
          {
            metric:,
            status:,
            count: relation.count.to_i,
            first_seen_on: date_value(relation.minimum(time_column)),
            last_seen_on: date_value(relation.maximum(time_column))
          }
        end

        def distinct_user_row(metric, status, relation, user_column:, time_column: :created_at)
          scoped = relation.where.not(user_column => nil)
          {
            metric:,
            status:,
            count: scoped.distinct.count(user_column).to_i,
            first_seen_on: date_value(scoped.minimum(time_column)),
            last_seen_on: date_value(scoped.maximum(time_column))
          }
        end

        def goodwill_transactions_in_window(kind, range)
          Decidim::Bih::Goodwill::Transaction
            .where(organization:, kind:, created_at: range)
            .count
        end

        def goodwill_points_in_window(kind, range, positive:)
          relation = Decidim::Bih::Goodwill::Entry
                     .joins(:ledger_transaction)
                     .where(organization:)
                     .where(decidim_bih_goodwill_transactions: { kind:, created_at: range })
          relation = if positive
                       relation.where("decidim_bih_goodwill_entries.amount > 0")
                     else
                       relation.where("decidim_bih_goodwill_entries.amount < 0")
                     end

          relation.sum("ABS(decidim_bih_goodwill_entries.amount)")
        end

        def approved_volunteer_hours_in_window(range)
          Decidim::Bih::VolunteerLog
            .where(organization:, status: "approved", created_at: range)
            .sum(:hours)
        end

        def broadcast_recipients_in_window(range)
          Decidim::Bih::Broadcast
            .where(organization:, created_at: range)
            .sum(:recipients_count)
        end

        def feedback_rating_in_window(value, range)
          Decidim::Bih::ConciergeFeedback
            .where(organization:, value:, created_at: range)
            .count
        end

        def usage_requests_in_window(range)
          Decidim::Bih::ConciergeUsageAggregate
            .where(organization:)
            .where(bucket_on: range.begin.to_date...range.end.to_date)
            .sum(:requests_count)
        end

        def current_trend_range
          current_trend_start...trend_now
        end

        def previous_trend_range
          previous_trend_start...current_trend_start
        end

        def current_trend_start
          trend_now - trend_window_days.days
        end

        def previous_trend_start
          current_trend_start - trend_window_days.days
        end

        def date_value(value)
          value&.to_date&.iso8601
        end

        def datetime_value(value)
          return if value.nil?

          value.to_time.utc.iso8601
        end

        def decimal_value(value)
          return if value.nil?

          BigDecimal(value.to_s).to_s("F")
        rescue ArgumentError
          value.to_s
        end

        def rounded_average(value)
          return if value.nil?

          BigDecimal(value.to_s).round(1).to_s("F")
        rescue ArgumentError
          nil
        end

        def rounded_ratio(total, count)
          count = count.to_i
          return if count.zero?

          (BigDecimal(total.to_s) / BigDecimal(count.to_s)).round(1).to_s("F")
        rescue ArgumentError
          nil
        end

        def rounded_percent(numerator, denominator)
          denominator = denominator.to_i
          return if denominator.zero?

          ((BigDecimal(numerator.to_s) / BigDecimal(denominator.to_s)) * 100).round(1).to_s("F")
        rescue ArgumentError
          nil
        end

        def decimal_trend_value(value)
          BigDecimal(value.to_s)
        rescue ArgumentError
          BigDecimal("0")
        end

        def trend_value(value)
          value = decimal_trend_value(value)
          return value.to_i if value.frac.zero?

          value.round(1).to_s("F")
        end

        def trend_percent(current_value, previous_value)
          previous_value = decimal_trend_value(previous_value)
          return if previous_value.zero?

          (((decimal_trend_value(current_value) - previous_value) / previous_value) * 100).round(1).to_s("F")
        end

        def value_of(object, key)
          return if object.nil?
          return object.public_send(key) if object.respond_to?(key)
          return object[key] || object[key.to_s] if object.respond_to?(:[])

          nil
        end

        def safe_csv_value(value)
          return value unless value.is_a?(String)
          return value unless value.match?(/\A[=+\-@\t\r]/)

          "'#{value}"
        end

        def review_example_text(value)
          value.to_s.squish.truncate(MI_BOT_REVIEW_EXAMPLE_TEXT_LIMIT, separator: " ").presence
        end
      end
    end
  end
end

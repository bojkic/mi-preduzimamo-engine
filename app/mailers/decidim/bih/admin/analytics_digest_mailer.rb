# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Sends opt-in, PII-safe aggregate analytics summaries to operators.
      # No CSV attachments and no raw report/chat/reward/Komsiluk content.
      class AnalyticsDigestMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
        DEFAULT_FROM = "notifications@example.org"
        DIGEST_LIMIT = 6

        def digest(organization:, recipient:, summary: nil)
          @organization = organization
          @recipient = recipient
          @summary = summary || Decidim::Bih::Admin::AnalyticsSummary.new(organization:)
          @sections = @summary.digest_sections(limit: DIGEST_LIMIT)
          @org_name = resolve_org_name(organization)

          mail(
            to: recipient,
            from: sender_address,
            subject: I18n.t("decidim.bih.admin.analytics.digest.subject", org: @org_name),
            body: body_text
          )
        end

        private

        def sender_address
          ENV.fetch("REPORTER_MAILER_FROM", nil).presence ||
            Decidim::Bih.reporter_mailer_from.presence ||
            DEFAULT_FROM
        end

        def body_text
          lines = [
            I18n.t("decidim.bih.admin.analytics.digest.heading", org: @org_name),
            I18n.t(
              "decidim.bih.admin.analytics.digest.generated_at",
              time: Time.current.strftime("%Y-%m-%d %H:%M")
            ),
            "",
            I18n.t("decidim.bih.admin.analytics.digest.privacy_note"),
            "",
            I18n.t("decidim.bih.admin.analytics.digest.datasets_heading")
          ]

          dataset_lines(lines)
          report_triage_lines(lines)
          review_section_lines(lines, "reward_fulfillment_review", :reward_line)
          review_section_lines(lines, "komsiluk_activity_review", :komsiluk_line)
          review_section_lines(lines, "mi_bot_review", :mi_bot_line)
          review_section_lines(lines, "mi_bot_review_comparison", :mi_bot_comparison_line)
          trend_lines(lines)
          host_reminder_lines(lines)

          lines << ""
          lines << I18n.t(
            "decidim.bih.admin.analytics.digest.review_link",
            url: "https://#{@organization.host}/admin/bih/analytics"
          )
          "#{lines.join("\n")}\n"
        end

        # Host-provided review reminders (Decidim::Bih.analytics_digest_reminders_provider),
        # e.g. "the foundation call-status review expires in 12 days". Aggregate
        # operational lines only; a missing or failing provider never blocks the digest.
        def host_reminder_lines(lines)
          provider = Decidim::Bih.analytics_digest_reminders_provider
          return unless provider.respond_to?(:call)

          reminders = Array(provider.call(organization: @organization)).map(&:to_s).compact_blank
          return if reminders.empty?

          lines << ""
          lines.concat(reminders)
        rescue StandardError => e
          Rails.logger.warn("[AnalyticsDigestMailer] reminders provider failed: #{e.class}")
        end

        def dataset_lines(lines)
          @sections.fetch(:overview).each do |dataset, count|
            lines << I18n.t(
              "decidim.bih.admin.analytics.digest.dataset_row",
              dataset: dataset_label(dataset),
              count:
            )
          end
        end

        def report_triage_lines(lines)
          lines << ""
          lines << I18n.t("decidim.bih.admin.analytics.digest.report_triage_heading")
          rows = @sections.fetch(:report_triage)
          return lines << I18n.t("decidim.bih.admin.analytics.digest.empty_section") if rows.empty?

          rows.each do |row|
            lines << I18n.t(
              "decidim.bih.admin.analytics.digest.report_triage_row",
              bucket: I18n.t("decidim.bih.admin.reports.index.sla.buckets.#{row[:bucket]}"),
              count: row[:count],
              priority: row[:review_priority],
              action: row[:review_action],
              oldest: row[:oldest_attention_on].presence || "-"
            )
          end
        end

        def review_section_lines(lines, dataset, formatter)
          lines << ""
          lines << I18n.t(
            "decidim.bih.admin.analytics.digest.review_heading",
            dataset: dataset_label(dataset)
          )
          rows = @sections.fetch(dataset.to_sym)
          return lines << I18n.t("decidim.bih.admin.analytics.digest.empty_section") if rows.empty?

          rows.each { |row| lines << send(formatter, row) }
        end

        def reward_line(row)
          I18n.t(
            "decidim.bih.admin.analytics.digest.reward_row",
            reward_key: row[:reward_key],
            priority: row[:review_priority],
            action: row[:review_action],
            open: row[:open_count],
            expired: row[:expired_open_count],
            expiring: row[:expiring_open_count]
          )
        end

        def komsiluk_line(row)
          I18n.t(
            "decidim.bih.admin.analytics.digest.komsiluk_row",
            area_slug: row[:area_slug],
            priority: row[:review_priority],
            action: row[:review_action],
            posts: row[:posts_count],
            flags: row[:total_flags],
            broadcasts: row[:broadcasts_count]
          )
        end

        def mi_bot_line(row)
          I18n.t(
            "decidim.bih.admin.analytics.digest.mi_bot_row",
            intent: row[:answer_intent],
            outcome: row[:outcome],
            answer_locale: row[:locale],
            priority: row[:review_priority],
            action: row[:review_action],
            feedback: row[:feedback_count],
            not_helpful: row[:not_helpful_count]
          )
        end

        # The one BOUNDED-window dataset in this digest. digest_sections has
        # computed it on every run since the digest existed and the body never
        # printed it, so the only figures an operator would have received were
        # cumulative ones — which have read "high" every week since the first
        # day ratings existed and therefore cannot report a change.
        #
        # Rendered through the existing trend_row key on purpose: the counts
        # are current vs previous window and no new locale key is introduced
        # for a line whose whole content is numbers. The counts are NOT-HELPFUL
        # RATINGS of rated turns, never a citizen accuracy figure.
        def mi_bot_comparison_line(row)
          I18n.t(
            "decidim.bih.admin.analytics.digest.trend_row",
            metric: "#{row[:answer_intent]}/#{row[:outcome]}/#{row[:locale]} not_helpful/#{row[:window_days]}d",
            current: row[:current_not_helpful_count],
            previous: row[:previous_not_helpful_count],
            change: row[:change_value],
            percent: row[:change_percent].presence || "-"
          )
        end

        def trend_lines(lines)
          lines << ""
          lines << I18n.t("decidim.bih.admin.analytics.digest.trends_heading")
          @sections.fetch(:trends).each do |row|
            lines << I18n.t(
              "decidim.bih.admin.analytics.digest.trend_row",
              metric: I18n.t("decidim.bih.admin.analytics.trend_metrics.#{row[:metric]}", default: row[:metric]),
              current: row[:current_value],
              previous: row[:previous_value],
              change: row[:change_value],
              percent: row[:change_percent].presence || "-"
            )
          end
        end

        def dataset_label(dataset)
          I18n.t("decidim.bih.admin.analytics.datasets.#{dataset}", default: dataset.to_s)
        end

        def resolve_org_name(organization)
          name = organization.name
          return organization.host if name.blank?

          if name.is_a?(Hash)
            locale = organization.try(:default_locale).to_s.presence || "sr"
            name[locale].presence || name.values.compact.first.presence || organization.host
          else
            name.to_s
          end
        end
      end
    end
  end
end

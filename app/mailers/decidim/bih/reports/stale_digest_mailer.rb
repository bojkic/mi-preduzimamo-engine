# frozen_string_literal: true

module Decidim
  module Bih
    module Reports
      # Sends the operator a plain-text summary of report triage buckets, plus
      # references for reports that have been forwarded or in-progress for more
      # than STALE_DAYS without resolution.
      # Triggered by the `decidim_bih:reports:stale_digest` rake task.
      # No reporter PII — only aggregate bucket counts and stale report
      # reference/status/date rows.
      class StaleDigestMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer
        DEFAULT_FROM = "notifications@example.org"

        # organization — Decidim::Organization
        # reports      — Array of Decidim::Bih::Report (already filtered to stale)
        # triage_rows  — Array of ReportTriageSummary rows
        # recipient    — operator email address (string)
        def digest(organization:, reports:, recipient:, triage_rows: nil)
          @organization = organization
          @reports = reports
          @triage_rows = triage_rows || Decidim::Bih::Admin::ReportTriageSummary.new(organization:).rows
          @attention_count = @triage_rows.sum { |row| row[:count].to_i }
          @stale_days = Decidim::Bih::Report::STALE_DAYS
          @org_name = resolve_org_name(organization)

          mail(
            to: recipient,
            from: sender_address,
            subject: I18n.t(
              "decidim.bih.reports.stale_digest.subject",
              org: @org_name,
              count: @attention_count
            ),
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
            I18n.t(
              "decidim.bih.reports.stale_digest.heading",
              org: @org_name
            ),
            I18n.t(
              "decidim.bih.reports.stale_digest.generated_at",
              time: Time.current.strftime("%Y-%m-%d %H:%M")
            ),
            "",
            I18n.t(
              "decidim.bih.reports.stale_digest.triage_heading",
              count: @attention_count
            ),
            ""
          ]

          @triage_rows.each { |row| lines << triage_line(row) }

          lines << ""
          lines << I18n.t(
            "decidim.bih.reports.stale_digest.stale_heading",
            count: @reports.size,
            days: @stale_days
          )

          if @reports.any?
            @reports.each do |report|
              lines << "  #{report.reference}  status=#{ReportStatusPresenter.label(report)}  " \
                       "datum=#{report.created_at.strftime("%Y-%m-%d")}"
            end
          else
            lines << I18n.t("decidim.bih.reports.stale_digest.no_stale")
          end

          lines << ""
          lines << I18n.t(
            "decidim.bih.reports.stale_digest.review_link",
            url: "https://#{@organization.host}/admin/bih/reports"
          )
          "#{lines.join("\n")}\n"
        end

        def triage_line(row)
          label = I18n.t("decidim.bih.admin.reports.index.sla.buckets.#{row[:key]}")
          oldest = row[:oldest_attention_on].presence || "-"
          latest = row[:latest_reported_on].presence || "-"

          I18n.t(
            "decidim.bih.reports.stale_digest.triage_row",
            bucket: label,
            count: row[:count],
            priority: row[:review_priority],
            action: row[:review_action],
            oldest: oldest,
            latest: latest
          )
        end

        # Organization#name is a translatable Hash in Decidim — resolve to a
        # plain string using the org's own default_locale, falling back to host.
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

# frozen_string_literal: true

namespace :decidim_bih do
  namespace :reports do
    namespace :second_reminders do
      desc "Read-only list of cases whose unanswered question is due for a second reminder"
      task :preview, [:host] => :environment do |_task, args|
        organization = Decidim::Organization.find_by!(host: args[:host].to_s)
        Decidim::Bih::ReportSecondReminders.due_reports.where(organization:).order(:id).each do |report|
          puts "#{report.reference} due_at=#{report.response_due_at.iso8601}"
        end
      end

      desc "Prepare and enqueue one Viber/WhatsApp second reminder for one reference. Requires CONFIRM=SEND_SECOND_REMINDER"
      task :send, [:host, :reference] => :environment do |_task, args|
        abort "explicit confirmation required" unless ENV["CONFIRM"] == "SEND_SECOND_REMINDER"
        organization = Decidim::Organization.find_by!(host: args[:host].to_s)
        report = Decidim::Bih::Report.find_by!(organization:, reference: args[:reference].to_s)
        reminder = Decidim::Bih::ReportSecondReminders.prepare!(report)
        puts "#{report.reference} queued reminder_id=#{reminder.id}"
      end

      desc "Reconcile Viber/WhatsApp delivery evidence for prepared second reminders; no sends"
      task :reconcile, [:host] => :environment do |_task, args|
        organization = Decidim::Organization.find_by!(host: args[:host].to_s)
        Decidim::Bih::ReportSecondReminder.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id }).find_each do |reminder|
          Decidim::Bih::ReportSecondReminders.reconcile!(reminder)
          puts "#{reminder.report.reference} #{reminder.reload.outcome} due_at=#{reminder.response_due_at&.iso8601 || "-"}"
        end
      end

      desc "Close delivered and unanswered second reminders after their 3-day deadline. Requires CONFIRM=CLOSE_SECOND_REMINDERS"
      task :close_due, [:host] => :environment do |_task, args|
        abort "explicit confirmation required" unless ENV["CONFIRM"] == "CLOSE_SECOND_REMINDERS"
        organization = Decidim::Organization.find_by!(host: args[:host].to_s)
        Decidim::Bih::ReportSecondReminder.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id }, outcome: "delivered")
                                          .where(response_due_at: ..Time.current).find_each do |reminder|
          puts "#{reminder.report.reference} #{Decidim::Bih::ReportSecondReminders.close_due!(reminder)}"
        end
      end
    end

    desc "Notify staff of overdue case deadlines and recover pending case notifications"
    task case_reminders: :environment do
      Decidim::Bih::ReportCaseReminderJob.perform_now
    end

    desc "Email each org's operator a PII-safe report triage digest. " \
         "Recipient resolves per org via the Setting override (namespace \"reports\", key \"operator_email\"), " \
         "falling back to BIH_OPERATOR_EMAIL; orgs with neither are skipped."
    task stale_digest: :environment do
      env_recipient = ENV.fetch("BIH_OPERATOR_EMAIL", nil)

      Decidim::Organization.find_each do |org|
        triage_rows = Decidim::Bih::Admin::ReportTriageSummary.new(organization: org).rows
        attention_count = triage_rows.sum { |row| row[:count].to_i }
        stale = Decidim::Bih::Report.stale.where(organization: org).order(:created_at)
        next if attention_count.zero?

        # Per-org override wins; the global ENV is only the fallback. An org with
        # neither a Setting override nor an ENV recipient is skipped (don't send).
        recipient = Decidim::Bih::Setting.namespace_for(org, "reports")["operator_email"].presence || env_recipient
        if recipient.blank?
          Rails.logger.info "[decidim_bih:reports:stale_digest] no recipient for #{org.host} — skipping " \
                            "(#{attention_count} attention item(s))"
          next
        end

        Decidim::Bih::Reports::StaleDigestMailer.digest(
          organization: org,
          reports: stale.to_a,
          triage_rows:,
          recipient: recipient
        ).deliver_now
        Rails.logger.info "[decidim_bih:reports:stale_digest] sent digest for #{org.host}: " \
                          "#{attention_count} attention item(s), #{stale.count} stale report(s)"
      end
    end

    desc "Mirror the city's Sistem 48 resolution status onto a host's reports " \
         "(closes the civic feedback loop). Usage: " \
         "rake decidim_bih:reports:sistem48_sync[host.example.org]. " \
         "No-op for an unknown host or an unconfigured scraper; fully rescued."
    task :sistem48_sync, [:host] => :environment do |_t, args|
      host = args[:host].to_s.presence
      abort "usage: rake decidim_bih:reports:sistem48_sync[HOST]" if host.nil?

      organization = Decidim::Organization.find_by(host: host)
      if organization.nil?
        Rails.logger.info "[decidim_bih:reports:sistem48_sync] no organization for host #{host} — skipping"
        next
      end

      updated = Decidim::Bih::Sistem48::ArchiveSync.new(organization).call
      Rails.logger.info "[decidim_bih:reports:sistem48_sync] #{host}: updated #{updated} report(s)"
    end

    desc "Backfill the admin full-text search index (search_text) for existing " \
         "reports. Usage: " \
         "rake \"decidim_bih:reports:backfill_search_text[host.example.org]\". " \
         "Idempotent — recomputes in place and writes only when the value " \
         "actually changes. Run it once after the migration; every later write " \
         "keeps itself current through the model callbacks."
    task :backfill_search_text, [:org_host] => :environment do |_t, args|
      org_host = args[:org_host].to_s.presence
      abort "usage: rake \"decidim_bih:reports:backfill_search_text[org_host]\"" if org_host.nil?

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      updated = 0
      unchanged = 0

      Decidim::Bih::Report.where(organization:).includes(:case_messages).find_each do |report|
        composed = report.composed_search_text
        if composed == report.search_text
          unchanged += 1
          next
        end

        report.refresh_search_text!
        updated += 1
      end

      puts "[decidim_bih:reports:backfill_search_text] #{org_host}: #{updated} updated, #{unchanged} already current"
    end

    desc "Backfill mz_slug on existing located reports so the per-MZ problem " \
         "heatmap is populated. Usage: " \
         "rake \"decidim_bih:reports:backfill_mz_slug[host.example.org]\". " \
         "Idempotent (re-running re-resolves in place); reports without " \
         "coordinates are skipped; one PointRouting call each, fully rescued."
    task :backfill_mz_slug, [:org_host] => :environment do |_t, args|
      org_host = args[:org_host].to_s.presence
      abort "usage: rake \"decidim_bih:reports:backfill_mz_slug[org_host]\"" if org_host.nil?

      organization = Decidim::Organization.find_by(host: org_host)
      abort "Organization not found for host: #{org_host}" unless organization

      scope = Decidim::Bih::Report
              .where(organization:)
              .where.not(latitude: nil)
              .where.not(longitude: nil)

      updated = 0
      skipped = 0

      scope.find_each do |report|
        slug = begin
          Decidim::Bih::Geo::PointRouting.resolve(
            lat: report.latitude,
            lon: report.longitude,
            organization:
          )[:mz_slug]
        rescue StandardError => e
          Rails.logger.warn "[decidim_bih:reports:backfill_mz_slug] routing failed for " \
                            "report #{report.id}: #{e.class}"
          nil
        end

        if slug.nil?
          skipped += 1
          next
        end

        # Single-column write, no callbacks: backfilling a derived slug must not
        # re-fire status notifications or re-stamp status_history.
        report.update_column(:mz_slug, slug) # rubocop:disable Rails/SkipsModelValidations
        updated += 1
      end

      Rails.logger.info "[decidim_bih:reports:backfill_mz_slug] #{org_host}: " \
                        "set mz_slug on #{updated} report(s), #{skipped} without a resolvable MZ"
    end
  end
end

namespace :decidim_bih do
  namespace :reports do
    desc "Read-only report mailbox poll"
    task mailbox_poll: :environment do
      target = Decidim::Bih::ReportMailbox::Target.resolve!
      Decidim::Bih::ReportMailboxIngestJob.perform_now(target.organization.id)
    end
    desc "Recover durable report mailbox processing"
    task mailbox_recover: :environment do
      target = Decidim::Bih::ReportMailbox::Target.resolve!
      Decidim::Bih::ReportMailboxRecoveryJob.perform_now(target.organization.id)
    end
    desc "Activate the report mailbox history watermark once"
    task mailbox_activate: :environment do
      Decidim::Bih::ReportMailbox::Target.activate!(organization_id: ENV.fetch("ORGANIZATION_ID"))
    end
  end
end

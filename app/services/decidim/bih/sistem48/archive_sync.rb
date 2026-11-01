# frozen_string_literal: true

module Decidim
  module Bih
    module Sistem48
      # Mirrors the city's public Sistem 48 resolution status back onto our
      # reports, closing the civic feedback loop opened by the e-mail forwarder.
      #
      # The whole point of mirroring the external city archive is that a citizen
      # who filed through the host front-end can see the city's answer here,
      # without ever leaving the platform.
      #
      #   Decidim::Bih::Sistem48::ArchiveSync.new(organization).call
      #   # => Integer (number of reports whose status was updated)
      #
      # Design notes:
      # * Org-scoped: only this organization's reports are considered.
      # * Single fetch: the archive is fetched ONCE per run and matched in
      #   memory. We deliberately do NOT call ArchiveScraper#status_for per
      #   report — that re-fetches the whole archive each time (an O(N) network
      #   N+1).
      # * No-op when unconfigured: a blank archive URL means we never touch the
      #   network and update nothing.
      # * Fully rescued: any scrape failure is logged and swallowed, so a flaky
      #   external site can never break the platform.
      # * Skips settled reports (TERMINAL_STATUSES) and those without a
      #   sistem48_reference — there is nothing to sync there.
      #
      # PII: the archive is PUBLIC city data; we store only the status text.
      class ArchiveSync
        attr_reader :organization, :scraper

        def initialize(organization, scraper: ArchiveScraper.new)
          @organization = organization
          @scraper = scraper
        end

        # Returns the number of reports updated (0 on no-op / failure).
        def call
          return 0 unless scraper.configured?

          status_by_reference = fetch_status_index
          return 0 if status_by_reference.nil?

          sync_reports(status_by_reference)
        end

        private

        # Fetches the archive once and builds a digits-only reference => status
        # lookup. Returns nil (signalling "abort, no updates") on any failure.
        def fetch_status_index
          scraper.fetch_archive.each_with_object({}) do |entry, index|
            reference = entry[:reference].to_s
            next if reference.empty?

            index[reference] = entry[:status]
          end
        rescue StandardError => e
          Rails.logger.error(
            "[Sistem48::ArchiveSync] archive fetch failed for #{organization&.host}: " \
            "#{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}"
          )
          nil
        end

        def sync_reports(status_by_reference)
          now = Time.current
          updated = 0

          syncable_reports.find_each do |report|
            status = status_by_reference[digits(report.sistem48_reference)]
            next if status.blank?

            report.with_lock do
              changed = report.sistem48_status != status
              report.update_columns(sistem48_status: status, sistem48_synced_at: now) # rubocop:disable Rails/SkipsModelValidations
              # A poll is not a city response. Only changed external information
              # moves the internal follow-up clock, and never a citizen task.
              if changed && report.forwarded_at && report.review_state == "validated" && Report::TERMINAL_STATUSES.exclude?(report.status)
                report.update!(response_due_at: now + ReportWorkQueue::CITY_DAYS.days, deadline_kind: "city")
              end
              report.record_event!("sistem48_status_synced", source: "background", actor_role: "system",
                                                             metadata: { sistem48_status: status, sistem48_synced_at: now, changed: })
            end
            updated += 1
          end

          updated
        end

        def syncable_reports
          Decidim::Bih::Report.where(organization: organization).sistem48_syncable
        end

        def digits(value)
          value.to_s.gsub(/\D/, "")
        end
      end
    end
  end
end

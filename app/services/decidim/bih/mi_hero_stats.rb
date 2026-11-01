# frozen_string_literal: true

module Decidim
  module Bih
    # Org-scoped figures for the homepage MI hero stats strip. Every stat is
    # computed independently and individually rescued — a broken query (or a
    # missing optional Decidim module) hides that one figure, never the page.
    # Results are cached for 10 minutes per organization; values are returned
    # pre-formatted (sr-RS style "600.000" dot separators) so the cell stays
    # presentation-only.
    class MiHeroStats
      CACHE_TTL = 10.minutes

      def self.for(organization)
        new(organization).stats
      end

      def initialize(organization)
        @organization = organization
      end

      # Returns an Array of { key:, value:, count: } Hashes (label i18n happens
      # in the cell template via the key, pluralized against count). count is
      # nil when the value isn't a countable noun (a percentage or the budget
      # total). Stats that are unavailable or zero are omitted; an empty Array
      # means "hide the whole strip".
      def stats
        cache_key = "decidim_bih/mi_hero_stats/v2-forwarded/#{organization.id}"
        cached = Rails.cache.read(cache_key)
        return cached if cached

        @incomplete = false
        result = compute
        # Only cache a FULL success. A transient per-stat failure must never be
        # frozen into the cache for the whole TTL — that would hide a recovered
        # figure on the homepage for up to 10 minutes.
        Rails.cache.write(cache_key, result, expires_in: CACHE_TTL) unless @incomplete
        result
      rescue StandardError => e
        log_error(:cache, e)
        compute
      end

      private

      attr_reader :organization

      def compute
        [citizens_stat, reports_total_stat, proposals_stat, campaign_stat, reports_sent_stat].compact
      end

      # Confirmed, not-blocked participants — same query core's
      # Decidim::StatsUsersCount uses for the organization stats.
      def citizens_stat
        count = Decidim::User.where(organization:).not_deleted.not_blocked.confirmed.count
        return if count.zero?

        { key: "citizens", value: delimited(count), count: count }
      rescue StandardError => e
        log_error(:citizens, e)
        nil
      end

      # Published proposals across the org's published components — the same
      # chain decidim-proposals registers for its :proposals_count stat.
      def proposals_stat
        return unless defined?(Decidim::Proposals::FilteredProposals)

        components = organization.published_components.where(manifest_name: "proposals")
        count = Decidim::Proposals::FilteredProposals.for(components).published.not_withdrawn.not_hidden.count
        return if count.zero?

        { key: "proposals", value: delimited(count), count: count }
      rescue StandardError => e
        log_error(:proposals, e)
        nil
      end

      # The campaign figure the foundation actually controls and can prove.
      #
      # This REPLACES the old budget tile, which summed the published budgets
      # components. That total was 600.000 KM of DEMO projects, so the homepage
      # advertised a number nobody could stand behind. Removed on the client's
      # instruction (2026-08-31); the demo budget component is unpublished by
      # rake mi:unpublish_demo_budget.
      CAMPAIGN_AMOUNT = "6.000 KM"

      def campaign_stat
        { key: "campaign", value: CAMPAIGN_AMOUNT, count: nil }
      end

      # Every problem report the organization has received, whatever its
      # status — the raw "how much has been reported" figure, next to the
      # verified forwarding count below. Not an activity floor candidate: the cell
      # lists it in UNFILTERED_STAT_KEYS so it shows from the first report.
      def reports_total_stat
        total = Decidim::Bih::Report.where(organization:).count
        return if total.zero?

        { key: "reports_total", value: delimited(total), count: total }
      rescue StandardError => e
        log_error(:reports_total, e)
        nil
      end

      # A completed action controlled by the platform. Count only recorded
      # forwarding, even if the city later resolves the report; queued/reviewed
      # cases and duplicate records do not establish a submission to services.
      def reports_sent_stat
        count = Decidim::Bih::Report.where(organization:, duplicate_of_report_id: nil).where.not(forwarded_at: nil).count
        return if count.zero?

        { key: "reports_sent", value: delimited(count), count: }
      rescue StandardError => e
        log_error(:reports_sent, e)
        nil
      end

      def delimited(number)
        ActiveSupport::NumberHelper.number_to_delimited(number, delimiter: ".")
      end

      def log_error(stat, error)
        # Any per-stat failure makes the computed set partial, so the caller must
        # not cache it (see #stats).
        @incomplete = true
        Rails.logger.error("[mi_hero_stats] #{stat}: #{error.class}: #{error.message}")
      end
    end
  end
end

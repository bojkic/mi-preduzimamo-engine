# frozen_string_literal: true

require "active_support/core_ext/string/filters"

module Decidim
  module Bih
    # Single source of truth for the per-status presentation of a citizen
    # report ("Bice riseno"): the legend/marker COLOUR and the pill TONE
    # (bg / ink / dot) on the Bijeljina palette.
    #
    # These maps were previously hand-duplicated across reports/show,
    # reports/index, reports/duplicate and reports_map/show. Keeping them here
    # means a palette change happens in ONE place and every surface stays in
    # sync.
    #
    #   Decidim::Bih::ReportStatusPresenter.for("rijeseno")
    #   # => { color: "#16a34a", tone: ["#e6efcf", "#46611f", "#9bbb5f"] }
    #
    # +color+ — the legend/map-marker colour for the status.
    # +tone+  — [background, ink, dot] for the status pill.
    #
    # Unknown/blank statuses fall back to the neutral grey tone the views
    # already used (DEFAULT_TONE / DEFAULT_COLOR), so behaviour is unchanged.
    class ReportStatusPresenter
      # Legend / map-marker colour per status.
      STATUS_COLORS = {
        "primljeno" => "#2c7fb8",
        "planirano" => "#64748b",
        "proslijedjeno" => "#f59e0b",
        "u_obradi" => "#eab308",
        "rijeseno" => "#16a34a",
        "odbijeno" => "#9ca3af"
      }.freeze

      # Pill tone [background, ink, dot] per status, on the Bijeljina palette.
      STATUS_TONES = {
        "primljeno" => ["#dcebf6", "#1c3d53", "#5b9bc4"],
        "planirano" => ["#eef1f3", "#374151", "#64748b"],
        "proslijedjeno" => ["#fdf6d6", "#7a5d10", "#f3cf5e"],
        "u_obradi" => ["#fdf6d6", "#7a5d10", "#f3cf5e"],
        "rijeseno" => ["#e6efcf", "#46611f", "#9bbb5f"],
        "odbijeno" => ["#eef1f3", "#51606b", "#9ca3af"]
      }.freeze

      # Neutral fallbacks for an unknown status — these are the literals the
      # views used as their `|| [...]` / default-colour fallback.
      DEFAULT_TONE = ["#eef1f3", "#51606b", "#9ca3af"].freeze
      DEFAULT_COLOR = "#9ca3af"

      # A duplicate is a display/filter outcome, not a new persisted lifecycle.
      REVIEW_DISPLAY_STATUSES = %w(needs_information under_review reviewed).freeze
      DISPLAY_STATUSES = ["duplicate", *REVIEW_DISPLAY_STATUSES].freeze
      DISPLAY_STATUS_SQL = <<~SQL.squish.freeze
        CASE WHEN duplicate_of_report_id IS NOT NULL THEN 'duplicate'
             WHEN status IN ('rijeseno', 'odbijeno') THEN status
             WHEN review_state = 'needs_information' THEN 'needs_information'
             WHEN review_state = 'pending' AND (reviewed_at IS NOT NULL OR last_citizen_reply_at IS NOT NULL) THEN 'under_review'
             WHEN status = 'primljeno' AND review_state = 'validated' THEN 'reviewed'
             ELSE status END
      SQL

      def self.status_key(value)
        return "duplicate" if value.respond_to?(:duplicate?) && value.duplicate?

        key = value.respond_to?(:status) ? value.status.to_s : value.to_s
        return key if Decidim::Bih::Report::TERMINAL_STATUSES.include?(key) || !value.respond_to?(:review_state)

        review_status_key(value, key)
      end

      def self.review_status_key(report, key)
        return "needs_information" if report.review_state == "needs_information"
        return "under_review" if report.review_state == "pending" && (report.reviewed_at.present? || report.last_citizen_reply_at.present?)
        return "reviewed" if key == "primljeno" && report.review_state == "validated"

        key
      end
      private_class_method :review_status_key

      def self.filter_statuses
        Decidim::Bih::Report::STATUSES + DISPLAY_STATUSES
      end

      def self.filter(scope, status)
        return scope if status.blank?

        scope.where("#{DISPLAY_STATUS_SQL} = ?", status)
      end

      def self.status_counts(scope)
        scope.group(Arel.sql(DISPLAY_STATUS_SQL)).count
      end

      def self.main_report(report)
        return unless report.duplicate?

        target = Decidim::Bih::Report.publicly_visible.where(decidim_organization_id: report.decidim_organization_id)
                                     .select(:id, :reference, :status, :duplicate_of_report_id, :review_state, :reviewed_at, :last_citizen_reply_at, :decidim_organization_id)
                                     .find_by(id: report.duplicate_of_report_id)
        target if target && target.decidim_organization_id == report.decidim_organization_id
      end

      def self.duplicate_message(report, locale: I18n.locale)
        target = main_report(report)
        return I18n.t("decidim.bih.reports.duplicate_display.unavailable", locale:) unless target

        I18n.t("decidim.bih.reports.duplicate_display.explanation", locale:, reference: target.reference)
      end

      # The [background, ink, dot] pill tone for a status (with neutral fallback).
      def self.tone(status)
        STATUS_TONES[status_key(status)] || DEFAULT_TONE
      end

      # The legend/marker colour for a status (with neutral fallback).
      def self.color(status)
        STATUS_COLORS[status_key(status)] || DEFAULT_COLOR
      end

      # Citizen-facing lifecycle key for a status.
      def self.public_status(status)
        Decidim::Bih::ReportServiceRequest.public_status_for(status)
      end

      # Citizen-facing lifecycle label for public report boundaries.
      def self.label(status, locale: I18n.locale)
        Decidim::Bih::ReportServiceRequest.public_label_for(status_key(status), locale:)
      end

      # Both presentation values for a status as a Hash, e.g. for views that
      # want them together.
      def self.for(status)
        { color: color(status), tone: tone(status) }
      end

      # { status => "#colour" } for every known status — the data the map and
      # the legend pass to the front-end.
      def self.colors
        Decidim::Bih::Report::STATUSES.index_with { |status| color(status) }
      end

      # { internal_status => public_label } for map/list public surfaces.
      def self.labels(locale: I18n.locale)
        Decidim::Bih::ReportStatusPresenter.filter_statuses.index_with { |status| label(status, locale:) }
      end
    end
  end
end

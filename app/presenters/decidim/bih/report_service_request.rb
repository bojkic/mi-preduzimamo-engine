# frozen_string_literal: true

module Decidim
  module Bih
    # Read-only service-request projection for a citizen report.
    #
    # The shape is intentionally inspired by Open311, but stays internal. It
    # gives future municipal adapters one place to map lifecycle statuses,
    # routing, external references, duplicate context and timeline events
    # without rewriting the existing BiH report model.
    class ReportServiceRequest
      PUBLIC_STATUS_BY_INTERNAL = {
        "primljeno" => "received",
        "planirano" => "planned",
        "proslijedjeno" => "sent_to_service",
        "u_obradi" => "in_progress",
        "rijeseno" => "resolved",
        "odbijeno" => "not_actionable"
      }.freeze

      PUBLIC_STATUS_ORDER = PUBLIC_STATUS_BY_INTERNAL.values.freeze
      INTERNAL_STATUS_BY_PUBLIC = PUBLIC_STATUS_BY_INTERNAL.invert.freeze

      EVENT_BY_PUBLIC_STATUS = {
        "received" => "request_received",
        "planned" => "request_planned",
        "sent_to_service" => "request_sent_to_service",
        "in_progress" => "request_in_progress",
        "resolved" => "request_resolved",
        "not_actionable" => "request_not_actionable",
        "needs_information" => "request_information_requested",
        "under_review" => "request_under_review",
        "reviewed" => "request_reviewed",
        "duplicate" => "request_linked_as_duplicate",
        "unknown" => "request_status_unknown"
      }.freeze

      ADAPTER_EVENTS = {
        service_discovery: "service_discovery",
        create_request: "create_request",
        request_status_lookup: "request_status_lookup",
        external_update_import: "external_update_import"
      }.freeze

      attr_reader :report

      def self.public_status_for(internal_status)
        key = ReportStatusPresenter.status_key(internal_status)
        return key if ReportStatusPresenter::DISPLAY_STATUSES.include?(key)

        PUBLIC_STATUS_BY_INTERNAL.fetch(key, "unknown")
      end

      def self.internal_status_for(public_status)
        INTERNAL_STATUS_BY_PUBLIC[public_status.to_s]
      end

      def self.public_label_for(status, locale: I18n.locale)
        public_status = normalize_public_status(status)
        I18n.t(
          "decidim.bih.reports.public_statuses.#{public_status}",
          locale:,
          default: public_status.to_s.humanize
        )
      end

      def self.public_options(locale: I18n.locale)
        Decidim::Bih::Report::STATUSES.map do |status|
          [public_label_for(status, locale:), status]
        end
      end

      def self.normalize_public_status(status)
        status = ReportStatusPresenter.status_key(status)
        return status if ReportStatusPresenter::DISPLAY_STATUSES.include?(status) || PUBLIC_STATUS_ORDER.include?(status)

        public_status_for(status)
      end

      def initialize(report)
        @report = report
      end

      def public_status
        self.class.public_status_for(report)
      end

      def public_status_label(locale: I18n.locale)
        self.class.public_label_for(public_status, locale:)
      end

      # Current platform work is separate from the durable city lifecycle.
      # Never infer delivery from approval, a queued job or an unknown outcome.
      def current_action
        waiting = ReportWorkQueue.waiting_on(report)
        return if waiting == "finished"
        return report.forwarded_at ? "sending_update" : "sending" if waiting == "sending"
        return waiting unless waiting == "review"

        review_action
      end

      def review_action
        return "review_forwarded" if report.review_state == "pending" && report.forwarded_at
        return "review" if report.review_state == "pending"
        return "checking_delivery" if report.dispatches.any? { |dispatch| dispatch.state == "unknown" }

        report.review_state == "validated" ? "reviewed" : "review"
      end

      private :review_action

      def current_action_label(locale: I18n.locale)
        action = current_action
        I18n.t("decidim.bih.reports.current_action.#{action}", locale:) if action
      end

      def event_type
        EVENT_BY_PUBLIC_STATUS.fetch(public_status, EVENT_BY_PUBLIC_STATUS.fetch("unknown"))
      end

      def update_history(locale: I18n.locale, serialize_times: false)
        history = report.resolution_timeline.map do |stage|
          public_status = if report.duplicate? && stage[:status] == "odbijeno"
                            "duplicate"
                          else
                            self.class.public_status_for(stage[:status])
                          end

          compact_hash(
            internal_status: stage[:status],
            public_status:,
            public_status_label: self.class.public_label_for(public_status, locale:),
            event_type: EVENT_BY_PUBLIC_STATUS.fetch(public_status, EVENT_BY_PUBLIC_STATUS.fetch("unknown")),
            reached: stage[:reached],
            at: serialize_times ? stage[:at]&.iso8601 : stage[:at],
            current: stage[:current]
          )
        end
        # Review work and collective planning are separate from city processing.
        # Preserve received history; show the current step without inventing a timestamp.
        if public_status == "planned" || ReportStatusPresenter::REVIEW_DISPLAY_STATUSES.include?(public_status)
          history.each { |stage| stage[:current] = false }
          position = history.rindex { |stage| stage[:reached] }.to_i + 1
          history.insert(position, { internal_status: report.status, public_status:,
                                     public_status_label: public_status_label(locale:), event_type:,
                                     reached: true, current: true })
        end
        history
      end

      def to_h(locale: I18n.locale, include_private_contact: false)
        compact_hash(
          service_category: report.category.presence,
          service_code: report.category.presence,
          request_reference: report.reference,
          public_status:,
          public_status_label: public_status_label(locale:),
          internal_status: report.status,
          current_action:,
          location: location,
          media: media,
          private_reporter_contact: reporter_contact(include_private_contact:),
          city_service_routing: city_service_routing,
          external_reference: report.sistem48_reference.presence,
          external_status: report.sistem48_status.presence,
          duplicate_cluster: duplicate_cluster,
          timestamps: timestamps,
          update_history: update_history(locale:, serialize_times: true)
        )
      end

      private

      def location
        compact_hash(
          address: report.address.presence,
          latitude: report.latitude,
          longitude: report.longitude,
          mz_slug: report.mz_slug.presence
        )
      end

      def media
        { photo_attached: report.photo.attached? }
      end

      def reporter_contact(include_private_contact:)
        contact = compact_hash(
          present: report.reporter_email.present? || report.reporter_phone.present?,
          anonymous: report.anonymous?
        )
        return contact unless include_private_contact

        contact.merge(
          compact_hash(
            email: report.reporter_email.presence,
            phone: report.reporter_phone.presence
          )
        )
      end

      def city_service_routing
        compact_hash(
          department: report.department.presence,
          severity: report.severity.presence,
          needs_operator_review: report.needs_review?
        )
      end

      def duplicate_cluster
        compact_hash(
          duplicate: report.duplicate?,
          duplicate_of_reference: ReportStatusPresenter.main_report(report)&.reference,
          duplicate_count: report.duplicate_reports.count,
          corroboration_count: report.corroboration_count.to_i
        )
      end

      def timestamps
        compact_hash(
          created_at: report.created_at&.iso8601,
          updated_at: report.updated_at&.iso8601,
          forwarded_at: report.forwarded_at&.iso8601,
          resolved_at: report.resolved_at&.iso8601,
          sistem48_synced_at: report.sistem48_synced_at&.iso8601
        )
      end

      def compact_hash(values)
        values.each_with_object({}) do |(key, value), hash|
          hash[key] = value unless blank_for_contract?(value)
        end
      end

      def blank_for_contract?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end
  end
end

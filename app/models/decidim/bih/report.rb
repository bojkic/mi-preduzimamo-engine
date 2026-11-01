# frozen_string_literal: true

require "securerandom"

module Decidim
  module Bih
    # A citizen problem report for the "Bice riseno" civic reporting feature.
    # Holds the raw submission plus the staff-reviewed classification (category,
    # department, severity, summary) and the Sistem 48 forwarding state.
    class Report < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_reports"

      # Lifecycle of a report as it moves through intake and processing.
      STATUSES = %w(primljeno planirano proslijedjeno u_obradi rijeseno odbijeno).freeze
      # Statuses past which a report is settled: it no longer needs the city's
      # external Sistem 48 status synced (Sistem48::ArchiveSync skips these).
      TERMINAL_STATUSES = %w(rijeseno odbijeno).freeze
      FORWARDING_ATTENTION_STATUSES = %w(primljeno).freeze

      # Threshold in days before a forwarded/in-progress report is considered stale.
      STALE_DAYS = 30
      STATUS_TOKEN_BYTES = 24
      STATUS_TOKEN_FORMAT = /\A[A-Za-z0-9_-]{32,}\z/
      # The report's own columns that feed the admin full-text index. Message
      # bodies are added on top of these in #composed_search_text.
      SEARCH_TEXT_COLUMNS = %w(reference description ai_summary address internal_note).freeze

      # Photo upload allowlist + size cap. This is a PUBLIC, anonymous endpoint,
      # so the photo must be constrained server-side: SVG is excluded (inline
      # XSS via the blob URL forwarded to Sistem 48) and size is capped (DoS).
      PHOTO_CONTENT_TYPES = %w(image/png image/jpeg image/webp).freeze
      PHOTO_MAX_BYTES = 5 * 1024 * 1024

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      # The logged-in citizen who filed the report, when there is one. Optional:
      # the intake surface is anonymous-first (web form + Viber bot), so most
      # reports have no author and earn no goodwill recognition.
      belongs_to :author,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id",
                 optional: true

      belongs_to :duplicate_of,
                 class_name: "Decidim::Bih::Report",
                 foreign_key: "duplicate_of_report_id",
                 optional: true
      has_many :duplicate_reports,
               class_name: "Decidim::Bih::Report",
               foreign_key: "duplicate_of_report_id",
               dependent: :nullify,
               inverse_of: :duplicate_of
      has_many :events,
               class_name: "Decidim::Bih::ReportEvent",
               foreign_key: "decidim_bih_report_id",
               dependent: :restrict_with_exception,
               inverse_of: :report

      belongs_to :report_collection, class_name: "Decidim::Bih::ReportCollection", optional: true
      belongs_to :location_reviewed_by, class_name: "Decidim::User", optional: true
      validates :location_kind, inclusion: { in: %w(description point segment) }
      validate :collection_in_organization
      validates :report_subtype, length: { maximum: 120 }

      def collection_in_organization
        errors.add(:report_collection, :invalid) if report_collection && report_collection.organization != organization
      end

      def planned? = status == "planirano"

      def collective? = report_collection_id.present?

      belongs_to :assigned_to, class_name: "Decidim::User", optional: true
      belongs_to :reviewed_by, class_name: "Decidim::User", optional: true
      has_many :review_proposals, class_name: "Decidim::Bih::ReportReviewProposal", dependent: :restrict_with_exception
      has_many :dispatches, class_name: "Decidim::Bih::ReportDispatch", dependent: :restrict_with_exception
      has_many :case_messages, class_name: "Decidim::Bih::ReportMessage", dependent: :restrict_with_exception, inverse_of: :report
      has_many :evidence_items, class_name: "Decidim::Bih::ReportEvidenceItem", dependent: :restrict_with_exception
      has_many :obligations, class_name: "Decidim::Bih::ReportObligation", dependent: :restrict_with_exception
      has_one :second_reminder, class_name: "Decidim::Bih::ReportSecondReminder", dependent: :restrict_with_exception
      REVIEW_STATES = %w(pending validated needs_information rejected).freeze
      validates :review_state, inclusion: { in: REVIEW_STATES }
      validates :severity, inclusion: { in: ReportTaxonomy::SEVERITIES.map(&:to_s) }, allow_nil: true
      validates :forwarding_note, length: { maximum: 3000 }
      validates :resolution_evidence, length: { maximum: 3000 }
      validates :forwarding_recipient, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
      validates :department, length: { maximum: 160 }
      validate :case_staff_in_organization

      has_one_attached :photo

      validates :description, presence: true
      validates :status, inclusion: { in: STATUSES }
      # Backed by the composite unique index [decidim_organization_id, reference].
      validates :reference, presence: true, uniqueness: { scope: :decidim_organization_id }
      validates :status_token,
                presence: true,
                uniqueness: { scope: :decidim_organization_id },
                format: { with: STATUS_TOKEN_FORMAT }
      validates :category,
                inclusion: { in: Decidim::Bih::ReportTaxonomy::CATEGORIES.map(&:to_s) },
                allow_nil: true
      validate :duplicate_target_same_organization
      validate :duplicate_target_not_self
      validate :acceptable_photo

      before_validation :initialize_review_deadline, on: :create
      before_validation :ensure_reference
      before_validation :ensure_status_token
      # Append a PII-free { status:, at: } entry to status_history on EVERY
      # status transition — including the initial intake (primljeno) — so the
      # public resolution timeline can be sourced from a single column no matter
      # which write path moved the report (admin, archive sync, intake). Runs in
      # the SAME write as the status change (before_save) so it is atomic.
      before_save :append_status_history, if: :status_history_changed?
      # Keep the full-text index current on the same write as the change that
      # invalidates it. Message bodies are folded in too (see
      # #composed_search_text), which is why ReportMessage refreshes its report
      # after a commit of its own.
      before_save :refresh_search_text, if: :search_text_stale?

      scope :resolved, -> { where(status: "rijeseno") }
      scope :pending, -> { where(status: "primljeno") }
      scope :forwarding_attention, lambda {
        where(status: FORWARDING_ATTENTION_STATUSES)
          .where.not(forwarding_failed_at: nil)
      }
      # Reports that have been forwarded/in-progress for longer than STALE_DAYS
      # without reaching a terminal status (rijeseno/odbijeno). Surfaces for the
      # operator stale digest and the admin dashboard.
      scope :stale, lambda {
        where(status: %w(proslijedjeno u_obradi))
          .where(created_at: ..STALE_DAYS.days.ago)
      }
      # Reports still worth syncing the city's external Sistem 48 status onto:
      # not yet settled in our own lifecycle and carrying a forwarded reference.
      scope :sistem48_syncable, lambda {
        where.not(status: TERMINAL_STATUSES)
             .where.not(sistem48_reference: [nil, ""])
      }
      scope :duplicates, -> { where.not(duplicate_of_report_id: nil) }
      scope :publicly_visible, -> { where(removed_from_public_at: nil) }
      # Operator-facing full-text search. The to_tsvector expression MUST stay
      # identical to the one in the GIN index (see the migration) or PostgreSQL
      # silently falls back to a sequential scan.
      #
      # A query that normalises to nothing (punctuation only) returns NOTHING
      # rather than everything: an operator who typed something and got the
      # unfiltered queue back would read it as "these all match".
      scope :full_text_search, lambda { |query|
        tsquery = Decidim::Bih::ReportSearchText.tsquery(query)
        next none if tsquery.blank?

        where("to_tsvector('simple', coalesce(search_text, '')) @@ to_tsquery('simple', ?)", tsquery)
      }

      # Fire reporter notifications on every status transition after primljeno.
      # Guarded to status changes only (no-op on other field updates). Never
      # raises — errors are rescued and logged so the callback chain is safe.
      before_update :remember_status_notification, if: :will_save_change_to_status?
      after_update_commit :deliver_pending_status_notification
      after_rollback :clear_pending_status_notification
      after_update :record_deadline_change
      after_update :close_waiting_obligations, if: :closed_by_this_save?
      after_create_commit :enqueue_review_proposal

      def record_deadline_change
        return unless saved_change_to_response_due_at? || saved_change_to_deadline_kind?

        prior_due = saved_change_to_response_due_at&.first || response_due_at_before_last_save
        prior_kind = saved_change_to_deadline_kind&.first || deadline_kind_before_last_save
        record_event!("case_deadline_changed", metadata: { from_due_at: prior_due, to_due_at: response_due_at,
                                                           from_deadline_kind: prior_kind, to_deadline_kind: deadline_kind })
      end

      # Every closing path (decision, automatic closure, legacy update) ends the
      # citizen and City waits; open tasks on closed cases were left behind before.
      def closed_by_this_save?
        entered_terminal = saved_change_to_status? && TERMINAL_STATUSES.include?(status) &&
                           TERMINAL_STATUSES.exclude?(status_before_last_save)
        entered_terminal || (saved_change_to_duplicate_of_report_id? && duplicate_of_report_id.present?)
      end

      def close_waiting_obligations
        ReportObligations.close_waiting!(self)
      end

      def enqueue_review_proposal
        ReportReviewAssistant.enqueue(self)
      end

      # Builds the primitive Hash the Sistem 48 forwarder expects. Anonymous
      # reports never expose a reporter contact.
      def initialize_review_deadline
        self.review_pending_since ||= created_at || Time.current if review_state == "pending"
        self.deadline_kind ||= "review"
      end

      def to_forwarder_hash
        {
          # Carried so Sistem48::DepartmentRouting can resolve per-organization
          # forwarding-target overrides (Decidim::Bih::Setting). Absent/nil
          # falls back to ENV/default routing, unchanged.
          organization_id: decidim_organization_id,
          recipient: forwarding_recipient.presence,
          reference: reference,
          category: category&.to_sym,
          department: department,
          severity: severity&.to_sym,
          description: [description, forwarding_note.presence].compact.join("\n\n"),
          address: address,
          lat: latitude,
          lng: longitude,
          photo_url: photo_url,
          reporter_contact: reporter_contact
        }
      end

      def tokenized_status_path
        Decidim::Bih.public_path("prijave/#{reference}/status/#{status_token}")
      end

      def record_forwarding_failure!(error, code: nil, source: "system")
        next_count = forwarding_failure_count.to_i + 1
        update!(
          forwarding_error_class: Decidim::Bih::SafeErrorMetadata.error_class(error),
          forwarding_error_message: Decidim::Bih::SafeErrorMetadata.error_message(error),
          forwarding_error_code: Decidim::Bih::SafeErrorMetadata.error_code(error, explicit: code),
          forwarding_failure_count: next_count,
          forwarding_failed_at: Time.current
        )
        record_event!(
          "forwarding_failed",
          source:,
          actor_role: source,
          metadata: {
            error_class: forwarding_error_class,
            error_code: forwarding_error_code,
            failure_count: next_count
          }
        )
      end

      def clear_forwarding_failure!(actor: nil, reason: nil, source: nil)
        previous_count = forwarding_failure_count.to_i
        previous_code = forwarding_error_code
        update!(
          forwarding_error_class: nil,
          forwarding_error_message: nil,
          forwarding_error_code: nil,
          forwarding_failure_count: 0,
          forwarding_failed_at: nil
        )
        return unless previous_count.positive? || previous_code.present?

        record_event!(
          "forwarding_failure_cleared",
          actor:,
          source: source || (actor ? "admin" : "system"),
          actor_role: actor ? "admin" : (source || "system"),
          metadata: {
            previous_failure_count: previous_count,
            previous_error_code: previous_code,
            reason:
          }
        )
      end

      # True once the city has published a Sistem 48 status that we have mirrored
      # onto this report. Drives whether the public tracker shows the city badge.
      def sistem48_status_known?
        sistem48_status.present?
      end

      def duplicate?
        duplicate_of_report_id.present?
      end

      def public_latitude
        public_location.latitude
      end

      def public_longitude
        public_location.longitude
      end

      # A typed address can identify a home as precisely as a map point. Keep it
      # off public cards unless the citizen explicitly chose exact publication.
      def public_address
        public_location.address
      end

      def record_event!(event_type, actor: nil, source: nil, actor_role: nil, metadata: {})
        return unless Decidim::Bih::ReportEvent.available?

        events.create!(
          event_type:,
          actor:,
          source: source || (actor ? "admin" : "system"),
          actor_role: actor_role || (actor ? "admin" : (source || "system")),
          occurred_at: Time.current,
          organization: organization,
          metadata: Decidim::Bih::ReportEvent.sanitize_metadata(metadata)
        )
      end

      # The ordered lifecycle the public resolution timeline renders. The final
      # outcome stage is whichever terminal status this report reached, defaulting
      # to "rijeseno" while it is still open (so the path to resolution is shown).
      def timeline_stages
        outcome = status == "odbijeno" ? "odbijeno" : "rijeseno"
        %w(primljeno proslijedjeno u_obradi) + [outcome]
      end

      # A PII-free, view-ready resolution timeline: one entry per lifecycle
      # stage with the timestamp at which the report reached it (nil if not yet
      # reached) and whether it is the report's CURRENT stage.
      #
      # Source of truth is status_history. For legacy rows with empty history we
      # fall back to the per-status timestamps we do have: created_at maps to
      # primljeno, forwarded_at to proslijedjeno, and updated_at to the report's
      # current status. Returns an Array of Hashes:
      #   { status:, reached:, at:, current: }
      def resolution_timeline
        reached_at = status_reached_at
        stages = timeline_stages
        current = stages.include?(status) ? status : stages.last

        stages.map do |stage|
          {
            status: stage,
            reached: reached_at.has_key?(stage),
            at: reached_at[stage],
            current: stage == current
          }
        end
      end

      # The time this report was marked resolved (reached "rijeseno"), or nil if
      # it never was. Sourced from status_reached_at so it shares the timeline's
      # history-with-fallback logic and zone normalization. Drives the public
      # map's "recently resolved" layer.
      def resolved_at
        return nil unless status == "rijeseno"

        status_reached_at["rijeseno"]
      end

      # Recompute and persist the search index for this report without touching
      # updated_at or running validations. Used by ReportMessage (whose own
      # commit changes what this report's text contains) and by the backfill
      # rake task.
      def refresh_search_text!
        update_column(:search_text, composed_search_text) # rubocop:disable Rails/SkipsModelValidations
      end

      # Everything an operator might search a report by, folded through the one
      # normaliser. Message bodies are included because the detail that names
      # the place is often in the citizen's REPLY, not in the description.
      # This is an admin-only index: internal_note is deliberately part of it.
      def composed_search_text
        parts = SEARCH_TEXT_COLUMNS.map { |column| self[column] }
        parts += case_messages.pluck(:body) if persisted?

        Decidim::Bih::ReportSearchText.normalize(parts.compact_blank.join(" "))
      end

      private

      # Every report is shown exactly where it was reported (decision of
      # 2026-09-07): the public map and list carry the exact point and the typed
      # address. The per-report `public_location_exact` column stays in the
      # schema but no longer drives anything.
      def case_staff_in_organization
        [assigned_to, reviewed_by].compact.each do |staff|
          errors.add(:base, :invalid) if staff.organization != organization
        end
      end

      def public_location
        Decidim::Bih::ReportPublicLocation.new(
          latitude:,
          longitude:,
          address:,
          exact: true
        )
      end

      # Map of status => Time it was reached, derived from status_history with a
      # graceful fallback to the discrete per-status timestamps for legacy rows.
      # Every timestamp is normalized into the application's configured zone so
      # the timeline reads in local time regardless of the request-scoped
      # Time.zone (which Rails resets to UTC mid-request).
      def status_reached_at
        raw = history_reached_at.presence || fallback_reached_at
        raw.transform_values { |t| t&.in_time_zone(application_time_zone) }.compact
      end

      def history_reached_at
        entries = status_history.is_a?(Array) ? status_history : []
        reached = entries.each_with_object({}) do |entry, acc|
          next unless entry.is_a?(Hash)

          stage = entry["status"]
          at = entry["at"]
          next if stage.blank? || at.blank?

          # First time each stage was reached wins (history is chronological).
          acc[stage] ||= parse_history_time(at)
        end.compact

        # The history "at" for the initial intake is stamped in a before_save a
        # hair before the row's own created_at is set, so prefer the canonical
        # created_at for the primljeno stage to keep the timeline consistent with
        # the "submitted on" field shown elsewhere on the page.
        reached["primljeno"] = created_at if reached.has_key?("primljeno") && created_at.present?
        reached
      end

      # Parse a stored ISO8601 history timestamp into a Time. Zone normalization
      # into the application zone is applied centrally in status_reached_at, so
      # here we just anchor the instant correctly (the stored value carries a Z
      # offset, so Time.zone.parse interprets it unambiguously).
      def parse_history_time(value)
        Time.zone.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def fallback_reached_at
        acc = { "primljeno" => created_at }
        acc["proslijedjeno"] = forwarded_at if forwarded_at.present?
        # Whatever the current status is, mark it reached at the last update so a
        # legacy row still shows its present stage on the timeline.
        acc[status] ||= updated_at if status.present?
        acc.compact
      end

      def application_time_zone
        ActiveSupport::TimeZone[Rails.application.config.time_zone] || Time.zone
      end

      def duplicate_target_same_organization
        return if duplicate_of.nil?
        return if duplicate_of.decidim_organization_id == decidim_organization_id

        errors.add(:duplicate_of_report_id, :invalid)
      end

      def duplicate_target_not_self
        return if duplicate_of.nil?
        return if id.blank? || duplicate_of_report_id != id

        errors.add(:duplicate_of_report_id, :invalid)
      end

      # Deliver a plain-text email notification to the reporter (when an email
      # address is on file) and a short Viber text (when a verified Linkage
      # for the reporter_phone exists). Both are enqueued asynchronously and
      # never raise into the callback chain.
      def remember_status_notification
        @pending_status_notification = true
      end

      def clear_pending_status_notification
        @pending_status_notification = false
      end

      def deliver_pending_status_notification
        return unless @pending_status_notification

        clear_pending_status_notification
        notify_reporter_of_status_change
      end

      def notify_reporter_of_status_change
        locale = organization&.default_locale.to_s.presence || "sr"

        notification = create_status_notification
        if notification
          push_result = WebPush.enqueue_with_claim_result(
            author, destination: "notifications", topic: :report_updates, notification_id: notification.id
          )
          case push_result
          when :not_claimed
            enqueue_status_alternate(locale)
          when :claimed_or_queued
            nil # The durable push intent owns this proactive route.
          else
            notification.update!(extra: notification.extra.to_h.merge("mi_report_push_claim" => "uncertain"))
            Rails.logger.warn("[Report] push claim requires reconciliation for #{reference}")
          end
        else
          enqueue_status_alternate(locale)
        end
      rescue StandardError => e
        Rails.logger.error(
          "[Report] notify_reporter_of_status_change failed for #{reference}: " \
          "#{Decidim::Bih::LogRedactor.error_message(e)}"
        )
      end

      def enqueue_status_alternate(locale)
        if Messaging::ProactiveEmail.report_allowed?(self)
          enqueue_email_notification(locale)
        else
          enqueue_viber_notification(locale)
        end
      end

      def create_status_notification
        return unless author && author.decidim_organization_id == decidim_organization_id
        return if author.deleted? || author.blocked?

        Decidim::Notification.create!(
          user: author, resource: author, event_name: "decidim.events.bih.report_status_update",
          event_class: "Decidim::Bih::ReportStatusUpdateEvent",
          extra: { report_id: id, reference:, status:, received_as: "affected_user" }
        )
      end

      def enqueue_email_notification(locale)
        return if reporter_email.blank?

        Decidim::Bih::ReporterMailer
          .status_update(self, locale: locale, host: organization&.host)
          .deliver_later(queue: :reports)
      end

      def enqueue_viber_notification(locale)
        # Only the authenticated report author owns this private update. A phone
        # entered on an anonymous report never selects someone else's account.
        return unless author && author.decidim_organization_id == decidim_organization_id

        status_label = Decidim::Bih::ReportStatusPresenter.label(self, locale:)
        text = I18n.with_locale(locale) do
          I18n.t("decidim.bih.reporter_mailer.status_update.viber_text", reference:, status: status_label)
        end
        if duplicate?
          explanation = ReportStatusPresenter.duplicate_message(self, locale:)
          text = "#{text}\n\n#{explanation}"
          status_label = "#{status_label}. #{explanation}"
        end
        if planned? && !duplicate?
          explanation = I18n.t("decidim.bih.report_planning.citizen_notification", locale:)
          text = "#{text}\n\n#{explanation}"
          status_label = "#{status_label}. #{explanation}"
        end
        reply_url = URI.join("https://#{organization.host}", tokenized_status_path).to_s
        text = "#{text}\n\n#{I18n.t("decidim.bih.report_case.reply_link", locale:)}: #{reply_url}"
        template = AccountNotifications.template_resolver&.call(topic: "report_updates", text:,
                                                                reference:, status: status_label)
        AccountNotifications.enqueue!(user: author, organization:, topic: :report_updates, text:,
                                      template:, deduplication_key: "report:#{id}:#{status}:#{updated_at.to_f}",
                                      message_class: "report.author_external_copy")
      end

      # Absolute URL: this is serialized into the e-mail forwarded to the
      # external Sistem 48 inbox, where a host-less path would be unfetchable.
      def photo_url
        return unless photo.attached?
        return if organization&.host.blank?

        Rails.application.routes.url_helpers.rails_blob_url(
          photo, host: organization.host, protocol: "https"
        )
      end

      # Server-side backstop so no code path (web form, service, future Viber
      # bot) can persist a report with an oversized or non-image photo.
      def acceptable_photo
        return unless photo.attached?

        blob = photo.blob
        if blob.byte_size.to_i > PHOTO_MAX_BYTES
          errors.add(:photo, :too_large, message: I18n.t("decidim.bih.reports.errors.photo_too_large"))
        elsif PHOTO_CONTENT_TYPES.exclude?(blob.content_type)
          errors.add(:photo, :invalid_type, message: I18n.t("decidim.bih.reports.errors.photo_invalid_type"))
        end
      end

      def reporter_contact
        return if anonymous?

        reporter_email.presence || reporter_phone.presence
      end

      # True when this save should append a history entry: any persisted status
      # transition, plus the very first save of a new record (initial intake →
      # primljeno). On create the in-memory `status` already equals the column
      # default, so `will_save_change_to_status?` is false — hence the new_record
      # branch to capture the entry point of the lifecycle.
      def status_history_changed?
        new_record? || will_save_change_to_status?
      end

      # Append the current status + a timestamp to the append-only lifecycle
      # log. PII-free by construction: only the status string and the time.
      # Defensive against a nil/garbage column value so a malformed legacy row
      # can never raise on its next status change.
      def append_status_history
        history = status_history.is_a?(Array) ? status_history.dup : []
        history << { "status" => status, "at" => Time.current.utc.iso8601 }
        self.status_history = history
      end

      # Assigns a human-friendly, per-organization sequential reference of the
      # form "BR-<YEAR>-<0001>". The counter is derived from the org's current
      # highest reference for the year — simple and good enough for intake.
      def ensure_reference
        return if reference.present?

        year = (created_at || Time.current).year
        self.reference = "BR-#{year}-#{format("%04d", next_sequence_for(year))}"
      end

      def ensure_status_token
        return if status_token.present?

        self.status_token = SecureRandom.urlsafe_base64(STATUS_TOKEN_BYTES)
      end

      def next_sequence_for(year)
        prefix = "BR-#{year}-"
        # MAX over the NUMERIC sequence part, not the string: a lexicographic
        # MAX would rank "BR-YYYY-9999" above "BR-YYYY-10000" and recompute 10000
        # forever once a year crosses four digits, colliding on every new report.
        max = self.class
                  .where(decidim_organization_id: decidim_organization_id)
                  .where("reference LIKE ?", "#{prefix}%")
                  .maximum(Arel.sql("CAST(split_part(reference, '-', 3) AS integer)"))

        (max || 0) + 1
      end

      # True when a column that feeds the search index changed on this write.
      def search_text_stale?
        search_text.nil? || SEARCH_TEXT_COLUMNS.any? { |column| send(:"#{column}_changed?") }
      end

      def refresh_search_text
        self.search_text = composed_search_text
      end
    end
  end
end

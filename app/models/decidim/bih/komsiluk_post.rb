# frozen_string_literal: true

require "uri"

module Decidim
  module Bih
    # Member-only notices. Source/author identity and personal response details
    # never escape the organization's board access and retention boundaries.
    class KomsilukPost < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_posts"
      self.filter_attributes += [:body, :details]

      FLAG_HIDE_THRESHOLD = 3
      CATEGORIES = %w(lost_pet safety activity general).freeze
      STATUSES = %w(open closed expired hidden).freeze
      ORIGINS = %w(citizen staff city_service legacy).freeze
      REVIEW_STATES = %w(unreviewed pending reviewed).freeze
      OUTCOMES = %w(resolved completed closed).freeze
      TITLE_MAX = 140
      BODY_MAX = 1_000
      PHOTO_MAX_BYTES = 5.megabytes
      DEFAULT_EXPIRY_DAYS = { "lost_pet" => 30, "safety" => 30 }.freeze
      OPTIONAL_EXPIRY_MAX_DAYS = 90
      MAX_REVISION_SNAPSHOTS = 20
      StaleRevision = Class.new(StandardError)
      NotEditable = Class.new(StandardError)

      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: "decidim_organization_id"
      belongs_to :author, class_name: "Decidim::User", foreign_key: "decidim_user_id", optional: true
      belongs_to :komsiluk, class_name: "Decidim::Bih::LocalArea"
      has_many :flags, class_name: "Decidim::Bih::KomsilukPostFlag", foreign_key: :decidim_bih_komsiluk_post_id,
                       dependent: :destroy, inverse_of: :post
      has_many :reviews, class_name: "Decidim::Bih::KomsilukPostReview", foreign_key: :decidim_bih_komsiluk_post_id, dependent: :destroy
      has_many :revisions, class_name: "Decidim::Bih::KomsilukPostRevision", foreign_key: :post_id, dependent: :destroy
      has_many :help_responses, class_name: "Decidim::Bih::KomsilukHelpResponse", foreign_key: :post_id, dependent: :destroy
      has_one_attached :photo

      validates :category, inclusion: { in: CATEGORIES }
      validates :status, inclusion: { in: STATUSES }
      validates :origin, inclusion: { in: ORIGINS }
      validates :review_state, inclusion: { in: REVIEW_STATES }
      validates :content_revision, numericality: { only_integer: true, greater_than: 0 }
      validates :title, presence: true, length: { maximum: TITLE_MAX }
      validates :body, presence: true, if: :open?
      validates :body, length: { maximum: BODY_MAX }, allow_nil: true
      validate :valid_board_scope
      validate :valid_activity
      validate :acceptable_photo
      before_validation :set_default_expires_at, on: :create

      CATEGORIES.each { |cat| define_method(:"#{cat}?") { category == cat } }
      STATUSES.each { |state| define_method(:"#{state}?") { status == state } }
      scope :visible, -> { where(status: "open").where("expires_at IS NULL OR expires_at > ?", Time.current) }
      scope :for_komsiluk, ->(komsiluk_id) { where(komsiluk_id:) }
      scope :flagged, -> { where(review_state: "pending") }

      def current?
        open? && (expires_at.nil? || expires_at > Time.current)
      end

      def effective_status
        open? && expires_at && expires_at <= Time.current ? "expired" : status
      end

      def display_origin = ORIGINS.include?(origin) ? origin : "legacy"

      def source_details = details.is_a?(Hash) && details["source"].is_a?(Hash) ? details["source"] : {}

      def activity_details = details.is_a?(Hash) && details["activity"].is_a?(Hash) ? details["activity"] : {}

      def source_urls = Array(source_details["urls"]).filter_map { |url| self.class.safe_link(url) }.uniq

      def sanitized_body = ActionController::Base.helpers.strip_tags(body.to_s)

      def urgent? = %w(lost_pet safety).include?(category)

      def help_enabled? = details.is_a?(Hash) && details["help_enabled"] == true && author.present?

      def self.safe_link(value)
        uri = URI.parse(value.to_s)
        return nil unless %w(http https).include?(uri.scheme) && uri.host.present? && uri.userinfo.nil?
        return nil if value.to_s.match?(/[\\\x00-\x20]/)

        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      def editable_by?(user)
        user && user.id == decidim_user_id && user.decidim_organization_id == decidim_organization_id &&
          %w(citizen legacy).include?(origin) && body.present? && (current? || hidden?)
      end

      # Review markers retain historic flags. Only distinct new flags since a
      # deliberate review count towards the next automatic hide threshold.
      def flag!(user)
        result = :already_flagged
        with_lock do
          unless flags.exists?(decidim_user_id: user.id)
            flags.create!(decidim_user_id: user.id)
            self.flagged_count += 1
            self.review_state = "pending"
            reviewed_count = details.to_h.dig("moderation", "reviewed_flag_count").to_i
            if flagged_count - reviewed_count >= FLAG_HIDE_THRESHOLD && open?
              self.status = "hidden"
              self.hidden_at = Time.current
              result = :auto_hidden
            else
              result = :flagged
            end
            save!
            Komsiluk::NoticePublishing.cancel_pending_for!(post: self, reason: "auto_hidden") if result == :auto_hidden
          end
        end
        result
      rescue ActiveRecord::RecordNotUnique
        :already_flagged
      end

      # Revision snapshots are private; public views show dates/outcomes, never
      # the hidden or withdrawn versions. Optimistic revision input prevents an
      # old form from overwriting a source/moderator or another browser's work.
      def correct!(by:, attributes:, expected_revision:, notify: false, photo_blob: nil, remove_photo: false, captured_recipient_ids: nil)
        with_lock do
          system_source = by.nil? && decidim_user_id.nil? && (origin == "city_service" || attributes[:origin] == "city_service" || attributes["origin"] == "city_service")
          staff_publisher = origin == "staff" && body.present? &&
                            OperatorAuthorization.allowed?(by, :broadcast_send_bell, organization:)
          raise NotEditable unless system_source || staff_publisher || editable_by?(by)
          raise StaleRevision unless expected_revision.to_i == content_revision

          before = revision_snapshot
          allowed = [:title, :body, :category, :expires_at]
          allowed += [:origin, :publication_key, :status] if system_source
          was_hidden = hidden?
          assign_attributes(attributes.symbolize_keys.slice(*allowed))
          self.status = "hidden" if was_hidden
          self.published_at ||= attributes[:published_at] || attributes["published_at"] if system_source
          incoming_details = (attributes[:details] || attributes["details"] || {}).deep_stringify_keys
          self.details = details.to_h.deep_merge(incoming_details)
          details["activity"] = incoming_details["activity"] if incoming_details.has_key?("activity")
          details["source_record"] = incoming_details["source_record"] if staff_publisher && incoming_details.has_key?("source_record")
          set_default_expires_at unless system_source
          changed = changed? || photo_blob.present? || (remove_photo && photo.attached?)
          if changed
            previous_revision = content_revision
            self.content_revision += 1
            photo.attach(photo_blob) if photo_blob
            photo.detach if remove_photo && !photo_blob
            self.review_state = "pending" if hidden? || review_state == "reviewed"
            save!
            revisions.create!(actor: by, content_revision: previous_revision, snapshot: before, notified: notify && current?)
            revisions.order(content_revision: :desc).offset(MAX_REVISION_SNAPSHOTS).update_all(snapshot: {}) # rubocop:disable Rails/SkipsModelValidations
            if current?
              if notify
                Komsiluk::NoticePublishing.publish!(post: self, captured_recipient_ids:, context: { notice_update: true })
              elsif !system_source
                Komsiluk::NoticePublishing.refresh_existing_revision!(post: self, previous_revision:)
              end
            end
          end
        end
        self
      end

      def close!(by:)
        resolve!(by:, outcome: "closed")
      end

      def resolve!(by:, outcome:)
        return false unless by && by.id == decidim_user_id && by.decidim_organization_id == decidim_organization_id && OUTCOMES.include?(outcome)

        result = false
        with_lock do
          if open?
            self.details = details.to_h.merge("outcome" => outcome)
            update!(status: "closed", closed_at: Time.current)
            Komsiluk::NoticePublishing.cancel_pending_for!(post: self, reason: "closed")
            result = true
          end
        end
        result
      end

      # Called by the host's existing post-body retention sweep. Never keep
      # full private history/media after its parent body has been scrubbed.
      def purge_private_history!
        revisions.delete_all
        help_responses.delete_all
        photo.purge if photo.attached?
        update_columns(details: {}) if details.present? # rubocop:disable Rails/SkipsModelValidations
      end

      private

      def revision_snapshot
        attributes.slice("title", "body", "category", "expires_at", "details")
      end

      def valid_board_scope
        errors.add(:komsiluk, :invalid) if komsiluk && (komsiluk.kind != "komsiluk" || komsiluk.decidim_organization_id != decidim_organization_id)
        errors.add(:author, :invalid) if author && author.decidim_organization_id != decidim_organization_id
      end

      def valid_activity
        return unless origin == "citizen"

        errors.add(:expires_at, :blank) if category == "activity" && expires_at.blank?
        action_url = activity_details["action_url"]
        errors.add(:details, I18n.t("decidim.bih.boards.errors.link")) if action_url.present? && self.class.safe_link(action_url).nil?
        return if activity_details["starts_at"].blank?

        starts = Time.iso8601(activity_details["starts_at"].to_s)
        errors.add(:expires_at, I18n.t("decidim.bih.boards.errors.end_before_start")) if expires_at.nil? || expires_at <= starts
      rescue ArgumentError
        errors.add(:details, I18n.t("decidim.bih.boards.errors.date"))
      end

      def acceptable_photo
        return unless photo.attached?

        if photo.blob.byte_size > PHOTO_MAX_BYTES || Media::ImageNormalizer::ALLOWED_CONTENT_TYPES.exclude?(photo.blob.content_type)
          errors.add(:photo, I18n.t("decidim.bih.boards.errors.photo"))
        end
      end

      def set_default_expires_at
        return if expires_at.present?

        days = DEFAULT_EXPIRY_DAYS[category]
        self.expires_at = days ? Time.current + days.days : nil
      end
    end
  end
end

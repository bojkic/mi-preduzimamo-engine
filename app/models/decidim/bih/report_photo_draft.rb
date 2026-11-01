# frozen_string_literal: true

module Decidim
  module Bih
    # Short-lived upload storage for the citizen duplicate interstitial. Tokens
    # are also bound to a private session nonce; a signed blob ID is never input.
    class ReportPhotoDraft < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_photo_drafts"
      self.filter_attributes += [:owner_digest]
      TTL = 2.hours
      Invalid = Class.new(StandardError)

      belongs_to :organization, class_name: "Decidim::Organization"
      belongs_to :consumed_report, class_name: "Decidim::Bih::Report", optional: true
      has_one_attached :photo
      validates :owner_digest, :expires_at, presence: true
      after_create_commit :schedule_cleanup
      scope :expired, -> { where(expires_at: ..Time.current) }

      def self.store!(organization:, owner:, upload:)
        raise Invalid if owner.blank? || !upload.respond_to?(:size) || upload.size > Report::PHOTO_MAX_BYTES

        normalized = Media::ImageNormalizer.call(upload)
        raise Invalid unless normalized && Report::PHOTO_CONTENT_TYPES.include?(normalized[:content_type])
        raise Invalid if normalized[:io].size > Report::PHOTO_MAX_BYTES

        draft = new(organization:, owner_digest: Digest::SHA256.hexdigest(owner), expires_at: TTL.from_now)
        draft.photo.attach(normalized)
        draft.save!
        draft
      ensure
        normalized[:io].close! if normalized
      end

      def token
        signed_id(purpose: :report_photo_draft, expires_at: expires_at)
      end

      def self.for_owner!(token:, organization:, owner:)
        raise Invalid if owner.blank?

        draft = find_signed(token, purpose: :report_photo_draft)
        raise Invalid unless draft && draft.organization_id == organization.id &&
                             ActiveSupport::SecurityUtils.secure_compare(draft.owner_digest, Digest::SHA256.hexdigest(owner))

        draft
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        raise Invalid
      end

      # Serialize consumption with expiry cleanup and repeated submissions.
      # Intake failure rolls back the report and leaves the upload available.
      def consume!
        with_lock do
          raise Invalid if expires_at <= Time.current
          next consumed_report if consumed_report_id.present?
          raise Invalid unless photo.attached?

          photo.blob.open do |file|
            report = yield(io: file, filename: photo.filename.to_s, content_type: photo.content_type)
            raise Invalid unless report&.persisted? && report.decidim_organization_id == organization_id && report.photo.attached?

            update!(consumed_report: report)
          end
          consumed_report
        end
      rescue ActiveRecord::RecordNotFound
        raise Invalid
      end

      def expire!
        with_lock { destroy! if expires_at <= Time.current }
      end

      def schedule_cleanup
        ReportPhotoDraftExpiryJob.set(wait_until: expires_at).perform_later(id)
      rescue StandardError => e
        # The existing daily reminder sweep recovers a scheduling gap.
        Rails.logger.error("[ReportPhotoDraft] expiry enqueue failed: #{e.class}")
      end

      def self.cleanup!
        expired.find_each do |draft|
          draft.expire!
        rescue ActiveRecord::RecordNotFound
          # Another sweep already removed this draft.
          next
        end
      end
    end
  end
end

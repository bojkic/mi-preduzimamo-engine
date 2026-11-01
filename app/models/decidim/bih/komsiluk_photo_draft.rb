# frozen_string_literal: true

module Decidim
  module Bih
    # A failed form can preserve its normalized photo for this account only.
    # Never accept a general ActiveStorage blob id from the browser.
    class KomsilukPhotoDraft < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_komsiluk_photo_drafts"
      TTL = 2.hours
      Invalid = Class.new(StandardError)
      belongs_to :organization, class_name: "Decidim::Organization"
      belongs_to :user, class_name: "Decidim::User"
      has_one_attached :photo
      after_create_commit :schedule_cleanup

      def self.store!(organization:, user:, upload:)
        valid_upload = upload.respond_to?(:tempfile) && upload.tempfile.respond_to?(:read) &&
                       upload.respond_to?(:content_type) && upload.respond_to?(:size) &&
                       upload.size.is_a?(Integer) && upload.size.positive? && upload.size <= KomsilukPost::PHOTO_MAX_BYTES
        raise Invalid unless user.organization == organization && valid_upload

        detected_type = Marcel::MimeType.for(upload.tempfile, name: nil, declared_type: nil)
        raise Invalid unless Media::ImageNormalizer::ALLOWED_CONTENT_TYPES.include?(detected_type) && detected_type == upload.content_type

        normalized = Media::ImageNormalizer.call(upload)
        raise Invalid unless normalized && normalized[:io].size <= KomsilukPost::PHOTO_MAX_BYTES

        normalized[:filename] = "komsiluk-photo#{Media::ImageNormalizer::EXTENSION_FOR.fetch(normalized[:content_type])}"
        user.with_lock do
          raise Invalid if where(organization:, user:).where("expires_at > ?", Time.current).count >= 3

          draft = new(organization:, user:, expires_at: TTL.from_now)
          draft.photo.attach(normalized)
          draft.save!
          draft
        end
      ensure
        normalized[:io].close! if normalized
      end

      def token
        signed_id(purpose: :komsiluk_photo_draft, expires_at: expires_at)
      end

      def self.for_owner!(token:, organization:, user:)
        draft = find_signed(token, purpose: :komsiluk_photo_draft)
        raise Invalid unless draft && draft.organization_id == organization.id && draft.user_id == user.id && draft.expires_at > Time.current

        draft
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        raise Invalid
      end

      def self.cleanup!
        where(expires_at: ..Time.current).find_each(&:expire!)
      end

      def expire!
        with_lock { destroy! if expires_at <= Time.current }
      rescue ActiveRecord::RecordNotFound
        nil
      end

      private

      def schedule_cleanup
        KomsilukPhotoDraftExpiryJob.set(wait_until: expires_at).perform_later(id)
      rescue StandardError => e
        Rails.logger.error("[KomsilukPhotoDraft] expiry enqueue failed: #{e.class}")
      end
    end
  end
end

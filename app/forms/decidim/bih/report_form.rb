# frozen_string_literal: true

module Decidim
  module Bih
    # Plain ActiveModel form backing the anonymous "Bice riseno" intake surface.
    # It guards the public-facing fields before the request is handed to
    # Decidim::Bih::ReportIntake, which owns persistence and enqueues the async
    # enrichment/forwarding work.
    class ReportForm
      include ActiveModel::Model
      include ActiveModel::Attributes

      LATITUDE_RANGE = -90.0..90.0
      LONGITUDE_RANGE = -180.0..180.0

      attribute :description, :string
      attribute :address, :string
      attribute :latitude, :float
      attribute :longitude, :float
      attribute :reporter_email, :string
      attribute :reporter_phone, :string
      attribute :anonymous, :boolean, default: false
      attribute :public_location_exact, :boolean, default: false
      attribute :website, :string
      # Set when the citizen, shown a possible-duplicate interstitial, chose
      # "it's different — submit anyway". The controller uses it to bypass
      # duplicate detection on the resubmit. Never persisted.
      attribute :confirmed_new, :boolean, default: false
      attribute :photo_draft_token, :string
      attribute :remove_saved_photo, :boolean, default: false

      # ActiveStorage uploads are not a castable ActiveModel attribute type, so
      # the raw uploaded file is carried as a plain accessor.
      attr_accessor :photo

      validates :description, presence: true
      # Reject bad uploads BEFORE the request reaches ReportIntake (which would
      # otherwise 500 on the model's photo validation). Mirrors the model's
      # allowlist/size cap against the raw uploaded file.
      validate :coordinates_within_ranges
      validate :acceptable_photo

      def honeypot_filled?
        website.present?
      end

      # The keyword arguments Decidim::Bih::ReportIntake#call expects, minus the
      # organization and locale which the controller injects from request state.
      def to_intake_attributes
        {
          description: description,
          address: address.presence,
          latitude: latitude,
          longitude: longitude,
          reporter_email: reporter_email.presence,
          reporter_phone: reporter_phone.presence,
          anonymous: anonymous,
          public_location_exact: public_location_exact,
          photo: photo
        }
      end

      # Fields that can safely round-trip through the possible-duplicate
      # interstitial when the citizen chooses "submit anyway". Uploaded files
      # stay server-side; an expiring session-bound token preserves the upload.
      def duplicate_resubmission_attributes
        {
          description: description,
          address: address.presence,
          latitude: latitude,
          longitude: longitude,
          reporter_email: reporter_email.presence,
          reporter_phone: reporter_phone.presence,
          anonymous: anonymous ? "1" : "0",
          public_location_exact: public_location_exact ? "1" : "0",
          photo_draft_token: photo_draft_token,
          confirmed_new: "1"
        }
      end

      private

      def coordinates_within_ranges
        validate_coordinate(:latitude, LATITUDE_RANGE)
        validate_coordinate(:longitude, LONGITUDE_RANGE)
      end

      def validate_coordinate(attribute, range)
        raw_value = raw_attribute_value(attribute)
        return if raw_value.blank?

        value = Float(raw_value)
        return if value.finite? && range.cover?(value)

        errors.add(attribute, :inclusion, message: "must be between #{range.begin} and #{range.end}")
      rescue ArgumentError, TypeError
        errors.add(attribute, :not_a_number)
      end

      def raw_attribute_value(attribute)
        active_model_attribute = @attributes[attribute.to_s]
        return public_send(attribute) unless active_model_attribute.respond_to?(:value_before_type_cast)

        active_model_attribute.value_before_type_cast
      end

      def acceptable_photo
        return if photo.blank?
        return unless photo.respond_to?(:size) && photo.respond_to?(:content_type)

        if photo.size.to_i > Decidim::Bih::Report::PHOTO_MAX_BYTES
          errors.add(:photo, I18n.t("decidim.bih.reports.errors.photo_too_large"))
        elsif Decidim::Bih::Report::PHOTO_CONTENT_TYPES.exclude?(photo.content_type)
          errors.add(:photo, I18n.t("decidim.bih.reports.errors.photo_invalid_type"))
        end
      end
    end
  end
end

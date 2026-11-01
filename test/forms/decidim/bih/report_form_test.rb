# frozen_string_literal: true

require "test_helper"
require "active_model"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/object/blank"
require "i18n"
require_relative "../../../../app/forms/decidim/bih/report_form"

module Decidim
  module Bih
    class ReportFormTest < Minitest::Test
      class Upload
        attr_reader :size, :content_type

        def initialize(size:, content_type:)
          @size = size
          @content_type = content_type
        end
      end

      class ReportConstraints
        PHOTO_MAX_BYTES = 10
        PHOTO_CONTENT_TYPES = %w(image/png image/jpeg image/webp).freeze
      end

      def test_to_intake_attributes_keeps_only_intake_fields_and_normalizes_optional_blanks
        photo = Upload.new(size: 5, content_type: "image/png")
        form = ReportForm.new(
          description: "Rupa na putu",
          address: "",
          latitude: "44.756",
          longitude: "19.216",
          reporter_email: "",
          reporter_phone: "+387 65 123 456",
          anonymous: "1",
          public_location_exact: "1",
          website: "bot-filled",
          confirmed_new: "1"
        )
        form.photo = photo

        assert_equal(
          {
            description: "Rupa na putu",
            address: nil,
            latitude: 44.756,
            longitude: 19.216,
            reporter_email: nil,
            reporter_phone: "+387 65 123 456",
            anonymous: true,
            public_location_exact: true,
            photo:
          },
          form.to_intake_attributes
        )
        assert_equal true, form.to_intake_attributes.has_key?(:photo)
        assert_equal false, form.to_intake_attributes.has_key?(:website)
        assert_equal false, form.to_intake_attributes.has_key?(:confirmed_new)
      end

      def test_duplicate_resubmission_attributes_exclude_honeypot_and_photo
        form = ReportForm.new(
          description: "Druga rupa",
          address: "Ulica 1",
          latitude: "44.756",
          longitude: "19.216",
          reporter_email: "reporter@example.org",
          reporter_phone: "+387 65 123 456",
          anonymous: "1",
          public_location_exact: "1",
          website: "bot-filled"
        )
        form.photo = Upload.new(size: 5, content_type: "image/png")

        assert_equal(
          {
            description: "Druga rupa",
            address: "Ulica 1",
            latitude: 44.756,
            longitude: 19.216,
            reporter_email: "reporter@example.org",
            reporter_phone: "+387 65 123 456",
            anonymous: "1",
            public_location_exact: "1",
            photo_draft_token: nil,
            confirmed_new: "1"
          },
          form.duplicate_resubmission_attributes
        )
        assert_equal false, form.duplicate_resubmission_attributes.has_key?(:website)
        assert_equal false, form.duplicate_resubmission_attributes.has_key?(:photo)
      end

      def test_duplicate_resubmission_attributes_preserve_false_anonymous_flag
        form = ReportForm.new(description: "Javna prijava", anonymous: "0")

        assert_equal "0", form.duplicate_resubmission_attributes.fetch(:anonymous)
        assert_equal "0", form.duplicate_resubmission_attributes.fetch(:public_location_exact)
        assert_equal "1", form.duplicate_resubmission_attributes.fetch(:confirmed_new)
      end

      def test_honeypot_filled_detects_bot_field
        assert ReportForm.new(website: "spam").honeypot_filled?
        assert_equal false, ReportForm.new(website: " ").honeypot_filled?
      end

      def test_coordinate_validation_accepts_blank_and_valid_values
        form = ReportForm.new(description: "Bez lokacije")
        assert form.valid?

        form = ReportForm.new(description: "Sa lokacijom", latitude: "44.756", longitude: "19.216")
        assert form.valid?
      end

      def test_coordinate_validation_rejects_non_numeric_and_out_of_range_values
        form = ReportForm.new(description: "Los unos", latitude: "north", longitude: "181")

        assert_equal false, form.valid?
        assert_includes form.errors[:latitude], "is not a number"
        assert_equal(
          true,
          form.errors[:longitude].any? { |message| message.include?("must be between -180.0 and 180.0") }
        )
      end

      def test_photo_validation_rejects_oversized_and_invalid_content_type
        with_report_constraints do
          oversized = ReportForm.new(description: "Prevelika slika")
          oversized.photo = Upload.new(size: 11, content_type: "image/png")

          assert_equal false, oversized.valid?
          assert oversized.errors[:photo].any?

          invalid_type = ReportForm.new(description: "Los tip slike")
          invalid_type.photo = Upload.new(size: 5, content_type: "text/plain")

          assert_equal false, invalid_type.valid?
          assert invalid_type.errors[:photo].any?
        end
      end

      private

      def with_report_constraints
        existed = Decidim::Bih.const_defined?(:Report, false)
        previous = Decidim::Bih.const_get(:Report) if existed
        Decidim::Bih.send(:remove_const, :Report) if existed
        Decidim::Bih.const_set(:Report, ReportConstraints)
        yield
      ensure
        Decidim::Bih.send(:remove_const, :Report) if Decidim::Bih.const_defined?(:Report, false)
        Decidim::Bih.const_set(:Report, previous) if existed
      end
    end
  end
end

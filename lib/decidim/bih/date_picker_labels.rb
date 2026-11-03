# frozen_string_literal: true

module Decidim
  module Bih
    # Core only initializes widget labels for datetime fields and loses them
    # when a caller already supplies data attributes. Cover both field types.
    module DatePickerLabels
      def date_field(attribute, options = {})
        super(attribute, mi_date_picker_options(attribute, options))
      end

      def datetime_field(attribute, options = {})
        super(attribute, mi_date_picker_options(attribute, options))
      end

      private

      def mi_date_picker_options(attribute, options)
        label = label_for(attribute)
        defaults = {
          "date-label" => I18n.t("datetime.widget.label.date", label:),
          "time-label" => I18n.t("datetime.widget.label.time", label:),
          "button-date-label" => I18n.t("datetime.widget.picker.date_button", label:),
          "button-time-label" => I18n.t("datetime.widget.picker.time_button", label:)
        }
        data = (options[:data] || {}).to_h.transform_keys { |key| key.to_s.tr("_", "-") }
        options.merge(data: defaults.merge(data.compact))
      end
    end
  end
end

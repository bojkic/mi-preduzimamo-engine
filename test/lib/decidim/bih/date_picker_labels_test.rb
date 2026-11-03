# frozen_string_literal: true

require "minitest/autorun"
require "i18n"
require_relative "../../../../lib/decidim/bih/date_picker_labels"
class DatePickerLabelsTest < Minitest::Test
  class BaseBuilder
    def date_field(_attribute, options = {}) = options

    def datetime_field(_attribute, options = {}) = options

    private

    def label_for(_attribute) = "Početak"
  end

  class Builder < BaseBuilder
    prepend Decidim::Bih::DatePickerLabels
  end

  def setup
    @previous = I18n.load_path.dup
    @locales = I18n.available_locales
    I18n.load_path += Dir[File.expand_path("../../../../config/locales/admin_upgrade.*.yml", __dir__)]
    I18n.available_locales = (@locales + [:sr, :"sr-Cyrl", :bs, :hr] + [I18n.locale]).uniq
    I18n.backend.reload!
  end

  def teardown
    I18n.load_path = @previous
    I18n.available_locales = @locales
    I18n.backend.reload!
  end
  %w(sr sr-Cyrl bs hr).each do |locale|
    define_method("test_#{locale.tr("-", "_")}_both_field_types_preserve_controller_and_supply_labels") do
      I18n.with_locale(locale) do
        [:date_field, :datetime_field].each do |method|
          options = { data: { controller: "date-picker" }.freeze }.freeze
          data = Builder.new.public_send(method, :start_date, options).fetch(:data)
          assert_equal "date-picker", data.fetch("controller")
          assert_equal I18n.t("datetime.widget.picker.date_button", label: "Početak"), data.fetch("button-date-label")
          assert_equal I18n.t("datetime.widget.picker.time_button", label: "Početak"), data.fetch("button-time-label")
          %w(date-label time-label button-date-label button-time-label).each do |key|
            refute_empty data.fetch(key)
            refute_match(/undefined|translation missing/i, data.fetch(key))
          end
        end
      end
    end
  end
  def test_explicit_custom_label_wins_without_losing_defaults
    I18n.with_locale(:sr) do
      data = Builder.new.date_field(:start_date, data: { button_date_label: "Poseban opis", controller: "date-picker" }).fetch(:data)
      assert_equal "Poseban opis", data.fetch("button-date-label")
      assert data.fetch("date-label").include?("Početak")
      assert_equal "date-picker", data.fetch("controller")
    end
  end

  def test_nil_data_receives_default_labels
    I18n.with_locale(:hr) do
      refute_empty Builder.new.date_field(:start_date, data: nil).fetch(:data).fetch("button-date-label")
    end
  end
end

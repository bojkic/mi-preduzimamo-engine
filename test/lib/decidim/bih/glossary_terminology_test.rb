# frozen_string_literal: true

require "test_helper"
require "yaml"

class GlossaryTerminologyTest < Minitest::Test
  LOCALES_DIR = File.expand_path("../../../../config/locales", __dir__)
  SYSTEM_LABELS = {
    "en" => "Goodwill",
    "sr" => "Ekonomija zajedništva",
    "bs" => "Ekonomija zajedništva",
    "hr" => "Ekonomija zajedništva",
    "sr-Cyrl" => "Економија заједништва"
  }.freeze
  LOCAL_LOCALES = %w(sr bs hr sr-Cyrl).freeze

  def test_value_system_uses_one_approved_name_per_language
    SYSTEM_LABELS.each do |locale, expected|
      data = locale_data(locale)

      assert_equal expected, data.dig("decidim", "bih", "admin", "menu", "goodwill"), locale
      assert_equal expected, data.dig("decidim", "bih", "admin", "navigation", "goodwill"), locale
      assert_equal expected, data.dig("decidim", "bih", "admin", "goodwill", "index", "title"), locale
    end
  end

  def test_local_copy_does_not_reintroduce_retired_goodwill_names
    LOCAL_LOCALES.each do |locale|
      visible_copy = flatten_strings(locale_data(locale)).join("\n")

      refute_match(/Goodwill|Гоодwилл/, visible_copy, locale)
      refute_match(/ekonomij\w* dobrote|економиј\w* доброте/i, visible_copy, locale)
      refute_match(/bod\w* dobre volje|бод\w* добре воље/i, visible_copy, locale)
    end
  end

  def test_technical_tenant_help_uses_platform_organization_term
    expected = {
      "en" => "this platform organization",
      "sr" => "ovoj organizaciji na platformi",
      "bs" => "ovoj organizaciji na platformi",
      "hr" => "ovoj organizaciji na platformi",
      "sr-Cyrl" => "овој организацији на платформи"
    }

    expected.each do |locale, phrase|
      help = locale_data(locale).dig(
        "decidim", "bih", "admin", "partner_profiles", "memberships", "search_help"
      )

      assert_includes help, phrase, locale
    end
  end

  private

  def locale_data(locale)
    YAML.safe_load_file(File.join(LOCALES_DIR, "#{locale}.yml"), aliases: true).fetch(locale)
  end

  def flatten_strings(value)
    case value
    when Hash
      value.values.flat_map { |child| flatten_strings(child) }
    when Array
      value.flat_map { |child| flatten_strings(child) }
    when String
      [value]
    else
      []
    end
  end
end

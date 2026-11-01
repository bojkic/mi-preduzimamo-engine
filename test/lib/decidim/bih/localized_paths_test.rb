# frozen_string_literal: true

require "test_helper"
require "yaml"

class LocalizedPathsTest < Minitest::Test
  LOCALES_DIR = File.expand_path("../../../../config/locales", __dir__)
  FORBIDDEN_HOST_TOKENS = [
    "Bijelj", "Бијељ",
    "LFBN", "ЛФБН",
    "fondacijabijeljina",
    "Lokalna fondacija", "Локална фондација",
    "#jervolimbijeljinu",
    "/biceriseno", "/бицерисено",
    "Mi pre(d)uzimamo", "Ми пре(д)узимамо",
    "Biće riješeno", "Биће ријешено",
    "MI! bot", "МИ! бот",
    "MI! platform", "МИ! платформ",
    "MI! app", "МИ! апликац",
    "MI! majica", "МИ! мајица",
    "MI! termos", "МИ! термос",
    "Instaliraj MI", "Инсталирај МИ",
    "Dodaj MI", "Додај МИ",
    "Dvorovi", "Дворови",
    "1300"
  ].freeze

  def test_visible_engine_defaults_do_not_name_bijeljina_host_copy
    locale_files.each do |path|
      data = YAML.safe_load_file(path)
      locale = data.keys.first
      values = [
        data.dig(locale, "decidim", "bih", "reporter_mailer", "status_update", "footer"),
        data.dig(locale, "decidim", "bih", "reporter_mailer", "status_update", "viber_text"),
        data.dig(locale, "decidim", "bih", "content_blocks", "mi_cta", "sub"),
        data.dig(locale, "decidim", "bih", "content_blocks", "mi_cta", "hashtag"),
        data.dig(locale, "decidim", "bih", "content_blocks", "mi_hero", "eyebrow"),
        data.dig(locale, "decidim", "bih", "content_blocks", "mi_hero", "sub_html"),
        data.dig(locale, "decidim", "bih", "komsiluk", "edit", "address_placeholder"),
        data.dig(locale, "decidim", "bih", "mi_bot", "show", "signoff", "line")
      ].compact.join("\n")

      assert_nil values.index("Bijelj"), path
      assert_nil values.index("Бијељ"), path
      assert_nil values.index("Lokalna fondacija"), path
      assert_nil values.index("Локална фондација"), path
      assert_nil values.index("#jervolimbijeljinu"), path
    end
  end

  def test_engine_locale_defaults_do_not_carry_bijeljina_campaign_copy
    locale_files.each do |path|
      strings = flatten_strings(YAML.safe_load_file(path)).join("\n")

      FORBIDDEN_HOST_TOKENS.each do |token|
        assert_nil strings.index(token), "#{path} leaked host token #{token.inspect}"
      end
    end
  end

  private

  def locale_files
    Dir[File.join(LOCALES_DIR, "*.yml")]
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

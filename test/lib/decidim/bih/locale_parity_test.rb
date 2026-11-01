# frozen_string_literal: true

require "test_helper"
require "yaml"

# Every key the engine owns must exist in every language it ships, and no
# language may carry a key the canonical file has lost. Two real gaps
# (volunteer.events.log in bs, and a misplaced org_bonus_recognitions.log in
# three files) sat in this tree unnoticed until a one-off script went looking,
# which is the argument for a standing test rather than another one-off.
#
# en.yml is canonical: it is the file every new key is written into first.
# sr/bs/hr are maintained by hand and sr-Cyrl is generated from sr by
# `rake decidim_bih:cyrillize`, so a sr-Cyrl failure here normally means the
# regeneration was skipped, not that anybody typed Cyrillic by hand.
#
# Pure YAML on purpose — no Rails, no I18n backend, no fallbacks. A fallback
# chain is exactly what hides a missing key at runtime, so the check has to
# read the files.
class LocaleParityTest < Minitest::Test
  LOCALES_DIR = File.expand_path("../../../../config/locales", __dir__)
  CANONICAL = "en"
  TRANSLATIONS = %w(sr bs hr sr-Cyrl).freeze

  # A pluralization node is ONE key for parity, never one key per category.
  # en carries `one`/`other`; sr, bs and hr correctly carry `one`/`few`/`other`
  # because BCS has a paucal. Comparing categories leaf by leaf reports every
  # correct `few` as an extra key — two dozen phantom findings that bury the
  # real ones.
  PLURAL_CATEGORIES = %w(zero one two few many other).freeze

  def test_every_engine_key_exists_in_every_language
    canonical = bih_keys(CANONICAL)

    refute_empty canonical, "en.yml carries no decidim.bih keys — the check would pass vacuously"

    TRANSLATIONS.each do |locale|
      keys = bih_keys(locale)

      assert_equal [], (canonical - keys),
                   "#{locale}.yml is missing decidim.bih keys that en.yml carries"
      assert_equal [], (keys - canonical),
                   "#{locale}.yml carries decidim.bih keys en.yml does not — a rename or a dead key"
    end
  end

  private

  def bih_keys(locale)
    bih = locale_data(locale).dig("decidim", "bih")
    return [] if bih.nil?

    flatten(bih).sort
  end

  def locale_data(locale)
    YAML.load_file(File.join(LOCALES_DIR, "#{locale}.yml")).fetch(locale)
  end

  def plural_node?(node)
    node.is_a?(Hash) && node.any? && node.keys.all? { |key| PLURAL_CATEGORIES.include?(key.to_s) }
  end

  def flatten(node, prefix = [], out = [])
    if plural_node?(node)
      out << "#{prefix.join(".")}[plural]"
    elsif node.is_a?(Hash)
      node.each { |key, value| flatten(value, prefix + [key.to_s], out) }
    else
      out << prefix.join(".")
    end
    out
  end
end

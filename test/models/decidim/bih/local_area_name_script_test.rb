# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "decidim/bih/transliterator"

# Unit coverage for the SCRIPT-AWARE display accessors on LocalArea
# (#translated_name, #display_predsjednik) in isolation from ActiveRecord/DB.
#
# Reference MZ/komšiluk + president names are imported from GeoJSON in Cyrillic
# and stored that way across all locale keys. Under the Latin locales (sr/bs/hr)
# they must DISPLAY in Latin; under sr-Cyrl they stay Cyrillic. The stored value
# is never mutated — these accessors transliterate at read time only.
#
# The real LocalArea inherits from Decidim::ApplicationRecord (needs a DB) and
# reads the script from I18n.locale, so — matching the login_token_test pattern
# — we exercise the accessor LOGIC against a minimal PORO that carries the exact
# same accessor bodies but takes the locale explicitly (no global I18n mutation,
# which the bare i18n config would reject). The transliteration itself is covered
# end-to-end in transliterator_test.rb.
module Decidim
  module Bih
    class LocalAreaNameScriptTest < Minitest::Test
      # Stand-in carrying the same accessor logic as Decidim::Bih::LocalArea,
      # except the active locale is injected instead of read from I18n.locale.
      class FakeArea
        attr_accessor :name, :predsjednik, :slug

        def initialize(name:, predsjednik: nil, slug: "centar")
          @name = name
          @predsjednik = predsjednik
          @slug = slug
        end

        def translated_name(locale_key)
          raw = name[locale_key] ||
                name[locale_key.split("-").first] ||
                name.values.compact.first ||
                slug
          Decidim::Bih::Transliterator.localize(raw, locale: locale_key)
        end

        def display_predsjednik(locale_key)
          Decidim::Bih::Transliterator.localize(predsjednik, locale: locale_key)
        end
      end

      CYRILLIC_NAME = {
        "sr" => "Дворови", "sr-Cyrl" => "Дворови",
        "bs" => "Дворови", "hr" => "Дворови"
      }.freeze

      def test_translated_name_renders_latin_under_latin_locales
        area = FakeArea.new(name: CYRILLIC_NAME)
        %w(sr bs hr).each do |locale|
          assert_equal "Dvorovi", area.translated_name(locale), "expected Latin under #{locale}"
        end
      end

      def test_translated_name_renders_cyrillic_under_sr_cyrl
        area = FakeArea.new(name: CYRILLIC_NAME)
        assert_equal "Дворови", area.translated_name("sr-Cyrl")
      end

      def test_translated_name_handles_all_caps_digraph_names
        area = FakeArea.new(name: { "sr" => "ЊЕГОШ" })
        assert_equal "NJEGOŠ", area.translated_name("sr")
        assert_equal "ЊЕГОШ", area.translated_name("sr-Cyrl")
      end

      def test_translated_name_falls_back_to_base_locale_then_any_then_slug
        # Missing exact "sr-Cyrl" key falls back to base "sr".
        area = FakeArea.new(name: { "sr" => "Центар" })
        assert_equal "Центар", area.translated_name("sr-Cyrl")

        # Empty name hash falls back to the slug, still script-localized.
        empty = FakeArea.new(name: {}, slug: "novi-grad")
        assert_equal "novi-grad", empty.translated_name("sr")
      end

      def test_display_predsjednik_follows_active_script
        area = FakeArea.new(name: CYRILLIC_NAME, predsjednik: "Ђорђе Ђурић")
        assert_equal "Đorđe Đurić", area.display_predsjednik("bs")
        assert_equal "Ђорђе Ђурић", area.display_predsjednik("sr-Cyrl")
      end

      def test_display_predsjednik_passes_blank_through
        area = FakeArea.new(name: CYRILLIC_NAME, predsjednik: nil)
        assert_nil area.display_predsjednik("sr")
      end
    end
  end
end

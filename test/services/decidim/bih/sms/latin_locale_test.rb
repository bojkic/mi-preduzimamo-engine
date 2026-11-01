# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/sms"

module Decidim
  module Bih
    module Sms
      # One rule, one place. Every text this platform puts in an SMS is
      # rendered under a Latin locale, and each sender used to decide that for
      # itself — which is how the passwordless login SMS ended up going out in
      # Cyrillic (UCS-2, and machine-transliterated at that) to sr-Cyrl
      # readers while the verification SMS did not.
      class LatinLocaleTest < Minitest::Test
        def test_cyrillic_serbian_falls_back_to_its_latin_sibling
          assert_equal :sr, Decidim::Bih::Sms.latin_locale_for("sr-Cyrl")
          assert_equal :sr, Decidim::Bih::Sms.latin_locale_for(:"sr-Cyrl")
        end

        def test_every_other_locale_is_passed_through_untouched
          [:sr, :bs, :hr, :en, "bs"].each do |locale|
            assert_equal locale, Decidim::Bih::Sms.latin_locale_for(locale), locale.inspect
          end
        end

        # Other files in this suite pin I18n.available_locales to their own
        # short lists, so relax the check for the duration rather than widen
        # (and thereby leak) theirs.
        def test_it_defaults_to_the_current_locale
          previous = I18n.enforce_available_locales
          I18n.enforce_available_locales = false
          I18n.with_locale(:"sr-Cyrl") { assert_equal :sr, Decidim::Bih::Sms.latin_locale_for }
        ensure
          I18n.enforce_available_locales = previous
        end
      end
    end
  end
end

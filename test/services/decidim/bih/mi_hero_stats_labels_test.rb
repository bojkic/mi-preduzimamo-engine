# frozen_string_literal: true

require "test_helper"
require "i18n"
require "i18n/backend/pluralization"
require "bigdecimal/util" # sr's OneFewOther pluralization rule calls Integer#to_d

module Decidim
  module Bih
    # Srpski traži one/few/other. Ovi testovi zaključavaju slaganje broja i
    # imenice u traci na naslovnoj — brojeve iz ove trake koristimo u kampanji.
    #
    # This suite runs outside a booted Rails app, so I18n has neither the
    # sr/bs/hr pluralization rules (normally registered by rails-i18n's
    # Railtie) nor config/locales/sr.yml loaded. setup/teardown replicate just
    # enough of that boot-time wiring — against the real locale file, not a
    # hand-copied fixture — so the assertions below exercise production data.
    class MiHeroStatsLabelsTest < Minitest::Test
      SCOPE = "decidim.bih.content_blocks.mi_hero.stats"
      LOCALE_FILE = File.expand_path("../../../../config/locales/sr.yml", __dir__)

      def setup
        @original_backend = I18n.backend
        @original_available_locales = I18n.available_locales
        @original_enforce_available_locales = I18n.enforce_available_locales
        @original_load_path = I18n.load_path.dup

        I18n.enforce_available_locales = false
        # Mix Pluralization into an anonymous subclass, not the shared
        # I18n::Backend::Simple class — Ruby can't un-include a module, so
        # including it directly would leak into every other test in the
        # process for the rest of the run. Swapping the backend reference
        # back in teardown fully undoes this.
        backend_class = Class.new(I18n::Backend::Simple) { include I18n::Backend::Pluralization }
        I18n.backend = backend_class.new
        I18n.backend.load_translations(pluralization_rule_file, LOCALE_FILE)
        I18n.available_locales = [:sr]
      ensure
        I18n.enforce_available_locales = @original_enforce_available_locales
      end

      def teardown
        I18n.backend = @original_backend
        I18n.available_locales = @original_available_locales
        I18n.enforce_available_locales = @original_enforce_available_locales
        I18n.load_path.replace(@original_load_path)
      end

      def test_resolved_reports_agree_with_the_number
        assert_equal "riješena prijava", label(:reports, 1)
        assert_equal "riješene prijave", label(:reports, 2)
        assert_equal "riješenih prijava", label(:reports, 5)
        assert_equal "riješenih prijava", label(:reports, 25)
      end

      def test_total_reports_agree_with_the_number
        assert_equal "prijava problema", label(:reports_total, 1)
        assert_equal "prijave problema", label(:reports_total, 2)
        assert_equal "prijave problema", label(:reports_total, 4)
        assert_equal "prijava problema", label(:reports_total, 5)
        assert_equal "prijava problema", label(:reports_total, 11)
        assert_equal "prijave problema", label(:reports_total, 22)
      end

      def test_citizens_agree_with_the_number
        assert_equal "aktivan građanin", label(:citizens, 1)
        assert_equal "aktivna građanina", label(:citizens, 2)
        assert_equal "aktivnih građana", label(:citizens, 50)
      end

      def test_proposals_agree_with_the_number
        assert_equal "prijedlog", label(:proposals, 1)
        assert_equal "prijedloga", label(:proposals, 2)
        assert_equal "prijedloga", label(:proposals, 5)
      end

      private

      def label(key, count)
        I18n.t("#{SCOPE}.#{key}", count: count, locale: :sr)
      end

      def pluralization_rule_file
        gem_dir = Gem::Specification.find_by_name("rails-i18n").gem_dir
        File.join(gem_dir, "rails", "pluralization", "sr.rb")
      end
    end
  end
end

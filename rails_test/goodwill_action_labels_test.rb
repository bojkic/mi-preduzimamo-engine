# frozen_string_literal: true

require "test_helper"
require "yaml"

module Decidim
  module Bih
    module RailsHarness
      # Svaka radnja u skali mora imati pravu oznaku u svakom jeziku, u OBA
      # mjesta gdje se oznake radnji prikazuju — bez oslanjanja na humanize
      # fallback, koji je ispisivao "Contribution offer" i na javnoj
      # (?tab=kako, community_hub/show.html.erb) i na admin
      # (/admin/bih/goodwill-settings, admin/goodwill_settings/edit.html.erb)
      # strani. Ta dva bloka su NEZAVISNI u locale fajlovima:
      #   - decidim.bih.goodwill.actions               (javna strana)
      #   - decidim.bih.admin.goodwill_settings.actions (admin strana)
      class GoodwillActionLabelsTest < ActiveSupport::TestCase
        # Generisani test host (rails_test/test_helper.rb's
        # BIH_RAILS_TEST_LOCALES) konfiguriše samo en/bs/hr/sr — sr-Cyrl nije
        # medju njima, pa Decidim priguši sr-Cyrl prevode iz runtime I18n
        # backend-a (isti razlog zbog kojeg decidim_bih_locale_parity_test.rb
        # u host aplikaciji cita YAML direktno umjesto preko I18n). Zato
        # sr-Cyrl ovdje provjeravamo citanjem fajla, a I18n.exists?/I18n.t
        # koristimo samo za lokale koje host stvarno ucitava.
        RUNTIME_LOCALES = %w(sr bs hr en).freeze
        SCOPES = %w(
          decidim.bih.goodwill.actions
          decidim.bih.admin.goodwill_settings.actions
        ).freeze

        test "every earning action has a real label in every runtime locale and every scope" do
          actions = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE.keys

          RUNTIME_LOCALES.each do |locale|
            SCOPES.each do |scope|
              actions.each do |action|
                key = "#{scope}.#{action}"

                assert I18n.exists?(key, locale),
                       "nedostaje #{key} za locale #{locale}"
              end
            end
          end
        end

        test "every earning action has a real label in sr-Cyrl.yml for every scope" do
          actions = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE.keys

          SCOPES.each do |scope|
            actions.each do |action|
              key = "#{scope}.#{action}"

              assert cyrl_leaf(key), "nedostaje #{key} za locale sr-Cyrl"
            end
          end
        end

        test "contribution offer is translated, not humanized on the public hub" do
          assert_equal "Ponuda doprinosa",
                       I18n.t("decidim.bih.goodwill.actions.contribution_offer", locale: :sr)
          assert_equal "Понуда доприноса",
                       cyrl_leaf("decidim.bih.goodwill.actions.contribution_offer")
        end

        test "contribution offer is translated, not humanized on the admin settings page" do
          assert_equal "Priznata ponuda doprinosa",
                       I18n.t("decidim.bih.admin.goodwill_settings.actions.contribution_offer", locale: :sr)
          assert_equal "Призната понуда доприноса",
                       cyrl_leaf("decidim.bih.admin.goodwill_settings.actions.contribution_offer")
        end

        test "the availability flash quotes the real schedule value, not a literal" do
          points = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE[:volunteer_availability]
          message = I18n.t("decidim.bih.volunteer.flash.availability_created",
                           count: points, locale: :sr)

          assert_includes message, points.to_s
          refute_includes message, "50", "broj se ne smije tvrdo upisivati u tekst"
        end

        private

        # Reads a dotted decidim.bih.* key straight out of the engine's
        # sr-Cyrl.yml (not via I18n), so the assertion reflects the file on
        # disk regardless of which locales the disposable test host loaded.
        def cyrl_leaf(dotted_key)
          @cyrl_root ||= YAML.load_file(
            File.join(ENV.fetch("ENGINE_ROOT"), "config", "locales", "sr-Cyrl.yml")
          ).fetch("sr-Cyrl")

          dotted_key.split(".").inject(@cyrl_root) { |node, segment| node && node[segment] }
        end
      end
    end
  end
end

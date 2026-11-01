# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "i18n"
require_relative "../../../../../app/services/decidim/bih/concierge/civic_shortcuts"

module Decidim
  module Bih
    module Concierge
      # Host-free coverage of the chip menu. Route helpers are injected; labels
      # and the canned "describe it" message come from the engine's own locale
      # files so the test proves the shipped copy, not a stub.
      class CivicShortcutsTest < Minitest::Test
        LOCALES_DIR = File.expand_path("../../../../../config/locales", __dir__)
        Routes = Struct.new(:new_report_path, :community_projects_path, :wallet_path,
                            :verification_explainer_path, :komsiluk_board_index_path, keyword_init: true)

        def setup
          @previous_enforce = I18n.enforce_available_locales
          I18n.enforce_available_locales = false
          %w(sr sr-Cyrl).each do |locale|
            path = File.join(LOCALES_DIR, "#{locale}.yml")
            I18n.load_path << path unless I18n.load_path.include?(path)
          end
          # Another suite may already have initialised the backend from a
          # shorter load path; reload so this file's keys are visible whatever
          # the test order.
          I18n.backend.reload!
          @defined_slug = !Decidim::Bih.respond_to?(:flagship_process_slug)
          Decidim::Bih.define_singleton_method(:flagship_process_slug) { "" } if @defined_slug
          @routes = Routes.new(
            new_report_path: "/biceriseno/prijave/new", community_projects_path: "/biceriseno/donacije",
            wallet_path: "/biceriseno/moj-doprinos", verification_explainer_path: "/biceriseno/verifikacija",
            komsiluk_board_index_path: "/biceriseno/komsiluk"
          )
        end

        def teardown
          I18n.enforce_available_locales = @previous_enforce
          Decidim::Bih.singleton_class.send(:remove_method, :flagship_process_slug) if @defined_slug
        end

        def test_the_report_entry_is_split_into_a_describe_chip_and_a_form_chip
          first, second = chips("sr").first(2)

          assert_equal I18n.t("decidim.bih.concierge.widget.quick.report_describe", locale: "sr"), first[:label]
          assert_equal I18n.t("decidim.bih.concierge.widget.quick.report_describe_send", locale: "sr"), first[:send]
          assert_equal "Želim prijaviti problem", first[:send]
          refute first.has_key?(:url), "the describe chip talks to the bot, it must not navigate"

          assert_equal I18n.t("decidim.bih.concierge.widget.quick.report_form", locale: "sr"), second[:label]
          assert_equal "/biceriseno/prijave/new", second[:url]
          refute second.has_key?(:send)
        end

        def test_every_chip_has_a_label_and_exactly_one_action
          chips("sr").each do |chip|
            assert chip[:label].present?, chip.inspect
            assert_equal 1, chip.slice(:url, :send).size, "one action per chip: #{chip.inspect}"
          end
        end

        def test_cyrillic_locale_renders_cyrillic_label_and_canned_message
          first = chips("sr-Cyrl").first

          assert_equal I18n.t("decidim.bih.concierge.widget.quick.report_describe", locale: "sr-Cyrl"), first[:label]
          assert_match(/\A[\p{Cyrillic}\s]+\z/, first[:send])
        end

        def test_the_form_chip_is_dropped_when_the_route_cannot_resolve
          routes = @routes.dup
          routes.define_singleton_method(:new_report_path) { raise "no route" }
          labels = CivicShortcuts.new(organization: nil, locale: "sr", routes:).chips.map { |chip| chip[:label] }

          refute_includes labels, I18n.t("decidim.bih.concierge.widget.quick.report_form", locale: "sr")
          assert_includes labels, I18n.t("decidim.bih.concierge.widget.quick.report_describe", locale: "sr")
        end

        private

        def chips(locale)
          CivicShortcuts.new(organization: nil, locale:, routes: @routes).chips
        end
      end
    end
  end
end

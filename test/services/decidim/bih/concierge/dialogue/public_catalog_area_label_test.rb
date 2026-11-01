# frozen_string_literal: true

require "test_helper"
require "i18n"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/public_catalog_empty_answer"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class PublicCatalogAreaLabelTest < Minitest::Test
          def setup
            @old_backend = I18n.backend
            @old_locales = I18n.available_locales
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.backend.load_translations(*Dir[File.expand_path("../../../../../../config/locales/decidim_bih_dialogue*.yml", __dir__)])
          end

          def teardown
            I18n.backend = @old_backend
            I18n.available_locales = @old_locales
          end

          def test_registry_kind_prefix_is_rendered_once_in_every_locale
            Contracts::LOCALES.product(%w(mz komsiluk)).each do |locale, kind|
              prefixes = kind == "mz" ? %w(MZ МЗ) : %w(Komšiluk Комшилук Neighborhood)
              prefixes.each do |prefix|
                read = result(kind:, label: "#{prefix} Dvorovi")
                before = Marshal.dump(read.coverage)
                reply = PublicCatalogEmptyAnswer.call(result: read, topic: "volunteer", locale:)
                name = I18n.t("decidim.bih.dialogue.catalog_area_#{kind}", locale:, name: "Dvorovi")
                expected = I18n.t("decidim.bih.dialogue.catalog_requested_areas", locale:, areas: name)
                assert_includes reply.lines.map(&:strip), expected
                assert_equal before, Marshal.dump(read.coverage)
              end
            end
          end

          def test_bare_names_and_unrelated_prefixes_remain_intact
            ["Dvorovi", "MZeta", "Komšiluk Dvorovi"].each do |label|
              reply = PublicCatalogEmptyAnswer.call(result: result(kind: "mz", label:), topic: "volunteer", locale: "sr")
              assert_includes reply, "Izabrano područje: MZ #{label}."
            end
          end

          private

          def result(kind:, label:)
            Contracts::ReadResult.new(status: "empty", source: { "id" => "platform:volunteer" },
                                      coverage: { "access" => "public", "complete_inventory" => false,
                                                  "requested_area_slugs" => ["dvorovi"],
                                                  "requested_areas" => [{ "kind" => kind, "slug" => "dvorovi", "label" => label }] },
                                      validity: { "timezone" => "Europe/Sarajevo" })
          end
        end
      end
    end
  end
end

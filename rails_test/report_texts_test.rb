# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportTextsTest < ActiveSupport::TestCase
        test "every reviewed template renders and Cyrillic is deterministic" do
          ReportTexts::KEYS.each do |key|
            slots = ReportTexts::SLOTS.fetch(key, []).index_with { 'Izjava iz predmeta' }
            latin = ReportTexts.render(key, slots:)
            assert latin.present?
            assert_equal Transliterator.call(latin), ReportTexts.render(key, slots:, locale: 'sr-Cyrl')
          end
        end
        test "unknown slots and unsafe composed text are refused" do
          assert_raises(ReportTexts::Invalid) { ReportTexts.render('exact_location', slots: { phone: 'secret' }) }
          ['Pozovite +38766123456', 'Otvorite https://example.org', 'riješićemo do petka'].each { |text| refute ReportTexts.safe_text?(text) }
        end
        test "a photo remains explicitly optional" do
          assert_includes ReportTexts.render('photo_helpful'), 'Ako želite'
        end
      end
    end
  end
end

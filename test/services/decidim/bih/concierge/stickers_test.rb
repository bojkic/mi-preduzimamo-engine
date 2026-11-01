# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/concierge/stickers"

module Decidim
  module Bih
    module Concierge
      class StickersTest < Minitest::Test
        Organization = Struct.new(:host)

        def test_persona_gestures_have_animated_web_and_static_provider_variants
          organization = Organization.new("mi.example.test")

          assert_equal(
            "https://mi.example.test/mi/milica/wave.gif",
            Stickers.url_for(:milica_wave, organization:, variant: :animated)
          )
          assert_equal(
            "https://mi.example.test/mi/milica/wave.jpg",
            Stickers.url_for(:milica_wave, organization:, variant: :static)
          )
        end

        def test_legacy_stickers_keep_their_png_path_for_both_variants
          organization = Organization.new("mi.example.test")

          assert_equal(
            "https://mi.example.test/mi/stickers/prijavljeno.png",
            Stickers.url_for(:prijavljeno, organization:, variant: :animated)
          )
          assert_equal(
            "https://mi.example.test/mi/stickers/prijavljeno.png",
            Stickers.url_for(:prijavljeno, organization:, variant: :static)
          )
        end

        def test_unknown_media_id_is_rejected
          assert_nil Stickers.url_for(:not_in_the_approved_pack, organization: Organization.new("mi.example.test"))
        end
      end
    end
  end
end

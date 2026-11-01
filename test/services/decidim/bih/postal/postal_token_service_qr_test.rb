# frozen_string_literal: true

require "test_helper"
require "rqrcode"

# Pure unit test for the QR rendering used on the printed postal letter.
#
# Regression: build_qr_svg used to pass `standalone: false` to rqrcode 2.x,
# which returns the bare <path> markup with NO <svg> wrapper element. Embedded
# in the letter that markup renders nothing at all — the printed letter showed
# only the confirm URL, and every mailed letter went out without a QR code.
#
# Loading the real service file would drag in LoginToken (ActiveRecord), which
# this suite deliberately has no Rails for, so the renderer is exercised
# through its extracted module.
require_relative "../../../../../app/services/decidim/bih/postal/qr_renderer"

module Decidim
  module Bih
    module Postal
      class QrRendererTest < Minitest::Test
        URL = "https://mi.fondacijabijeljina.com/v/EXAMPLETOKEN123456"

        def test_renders_a_complete_svg_element
          svg = QrRenderer.render(URL)

          assert svg.start_with?("<svg"), "expected a full <svg> element, got: #{svg[0, 60]}"
          assert_includes svg, "</svg>"
        end

        def test_omits_the_xml_prolog_so_it_can_be_inlined_in_html
          refute_includes QrRenderer.render(URL), "<?xml"
        end

        def test_carries_a_viewbox_so_css_can_size_it_for_print
          assert_match(/viewBox="0 0 \d+ \d+"/, QrRenderer.render(URL))
        end

        def test_encodes_the_url_it_was_given
          # Two different URLs must not produce identical modules.
          refute_equal QrRenderer.render(URL), QrRenderer.render("#{URL}X")
        end

        def test_returns_nil_when_the_payload_cannot_be_encoded
          # A payload beyond QR capacity raises inside rqrcode; the letter must
          # still print (with the code and the URL) rather than 500.
          assert_nil QrRenderer.render("x" * 10_000)
        end
      end
    end
  end
end

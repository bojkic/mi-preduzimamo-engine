# frozen_string_literal: true

require "rqrcode"

module Decidim
  module Bih
    module Postal
      # Renders a confirm URL as an inline SVG QR code for the printed letter.
      #
      # WHY THIS IS NOT `as_svg(standalone: false)`: in rqrcode 2.x that option
      # returns only the <path> markup, with no <svg> wrapper. Dropped into the
      # letter it renders nothing — which is exactly how every postal letter
      # went out without a QR code. `standalone: true` emits a complete element
      # but prefixes an XML prolog that is invalid inside an HTML document, so
      # the prolog is stripped. Same shape as Goodwill::InviteLinks#qr_svg.
      #
      # `viewbox: true` is what lets the letter size the code in millimetres for
      # print instead of being stuck with rqrcode's pixel module size.
      module QrRenderer
        # Correction level :m survives the ~7% of the code an envelope window or
        # a fold typically obscures without inflating the module count.
        LEVEL = :m
        MODULE_SIZE = 6

        module_function

        # Returns a complete, inlineable <svg> string, or nil when the payload
        # cannot be encoded. Never raises: a letter missing its QR must still
        # print, because it still carries the 6-digit code and the typed URL.
        def render(url)
          RQRCode::QRCode.new(url.to_s, level: LEVEL)
                         .as_svg(module_size: MODULE_SIZE, standalone: true, use_path: true, viewbox: true)
                         .sub(/\A<\?xml[^>]*\?>\s*/, "")
        rescue StandardError => e
          logger&.error("[postal] QR not rendered: #{e.class}: #{e.message}")
          nil
        end

        def logger
          Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
        end
      end
    end
  end
end

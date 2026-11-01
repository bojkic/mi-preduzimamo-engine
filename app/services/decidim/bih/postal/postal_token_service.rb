# frozen_string_literal: true

require_relative "qr_renderer"

module Decidim
  module Bih
    module Postal
      # Mints a LoginToken (purpose: "postal") and builds the confirm URL and
      # optional QR SVG that are printed on the mailed letter.
      #
      # The raw token is NEVER logged — callers receive the URL/QR struct and
      # must pass it directly to the view without logging or storing.
      #
      # QR rendering is delegated to {QrRenderer}, which renders an inline SVG
      # locally. This avoids any external QR API call and keeps the token off
      # third-party servers.
      #
      # Usage:
      #   result = PostalTokenService.issue_for_authorization(authorization, host:)
      #   result.confirm_url   # => Decidim::Bih.magic_link_url(raw, host:)
      #   result.qr_svg        # => "<svg>...</svg>" (inline, safe to embed)
      class PostalTokenService
        Result = Struct.new(:confirm_url, :qr_svg, keyword_init: true)

        class << self
          # Mint a new postal token for the user that owns +authorization+ and
          # return a Result with the confirm URL and QR SVG.
          #
          # +host+ is the organization's public hostname (used to build the URL).
          def issue_for_authorization(authorization, host:)
            user = authorization.user
            raw = LoginToken.issue!(user:, purpose: "postal")
            url = build_url(raw, host:)
            svg = build_qr_svg(url)
            Result.new(confirm_url: url, qr_svg: svg)
          end

          private

          def build_url(raw, host:)
            Decidim::Bih.magic_link_url(raw, host:)
          end

          def build_qr_svg(url)
            QrRenderer.render(url)
          end
        end
      end
    end
  end
end
